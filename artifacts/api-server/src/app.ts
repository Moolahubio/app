import { STATUS_CODES } from "node:http";
import express, { type Express, type Request, type Response, type NextFunction } from "express";
import cors from "cors";
import helmet from "helmet";
import rateLimit from "express-rate-limit";
import cookieParser from "cookie-parser";
import pinoHttp from "pino-http";
import router from "./routes";
import { logger } from "./lib/logger";
import { isAllowedOrigin } from "./lib/origins";
import { captureServerError } from "./lib/observability";
import { AppError } from "./lib/errors";
import { requestLogFields } from "./lib/requestLog";

const app: Express = express();

// Behind a reverse proxy (Replit and most hosts): needed so `secure` cookies and
// per-client rate limiting see the real client IP / protocol.
app.set("trust proxy", 1);
app.disable("x-powered-by");

app.use(
  pinoHttp({
    logger,
    serializers: {
      req(req) {
        return requestLogFields(req, process.env.NODE_ENV === "production");
      },
      res(res) {
        return { statusCode: res.statusCode };
      },
    },
  }),
);

// Security headers (CSP, HSTS, X-Content-Type-Options, frameguard, etc.).
app.use(helmet());

// CORS: only allow credentialed requests from allowlisted origins
// (ALLOWED_ORIGINS + REPLIT_DOMAINS — the domains this server is served on).
// Requests with no Origin header (same-origin, server-to-server, health checks)
// are allowed. Never reflect an arbitrary origin while credentials are enabled.
app.use(
  cors({
    origin(origin, cb) {
      if (isAllowedOrigin(origin)) return cb(null, true);
      // Don't throw — just omit CORS headers so the browser blocks it.
      return cb(null, false);
    },
    credentials: true,
  }),
);

app.use(cookieParser());
app.use(express.json({ limit: "1mb" }));
app.use(express.urlencoded({ extended: true, limit: "1mb" }));

/**
 * Per-IP request budget for a limiter. Local development may raise it through
 * the named env var (a native dev build re-checks /auth/me on every launch and a
 * QA session easily spends 20 auth calls in 15 minutes). In production the
 * override is ignored and the hard default always applies.
 */
function limiterMax(envVar: string, fallback: number): number {
  if (process.env.NODE_ENV === "production") return fallback;
  const n = Number(process.env[envVar]);
  return Number.isInteger(n) && n > 0 ? n : fallback;
}

// Rate limiting (per IP). Auth endpoints get a much tighter budget to blunt
// credential stuffing / brute force.
const apiLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: limiterMax("DEV_API_RATE_LIMIT_MAX", 300),
  standardHeaders: true,
  legacyHeaders: false,
});
const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: limiterMax("DEV_AUTH_RATE_LIMIT_MAX", 20),
  standardHeaders: true,
  legacyHeaders: false,
});
app.use("/api/auth", authLimiter);
app.use("/api", apiLimiter);

app.use("/api", router);

// 404 for unmatched API routes.
app.use((_req: Request, res: Response) => {
  res.status(404).json({ error: "Not found" });
});

/**
 * The 4xx a client error carries: an AppError, or an http-errors error from
 * Express middleware (body-parser marks those `expose: true`). Upstream errors
 * that merely carry a status (an RPC's 429, say) are not client errors.
 */
function clientErrorStatus(err: unknown): number | undefined {
  if (err instanceof AppError) return err.statusCode < 500 ? err.statusCode : undefined;
  const e = err as { status?: unknown; expose?: unknown } | null;
  return e?.expose === true && typeof e.status === "number" && e.status >= 400 && e.status < 500 ? e.status : undefined;
}

// Global error handler (last middleware). Logs the full error server-side and
// returns a generic message; never leaks stack traces or internals. Express 5
// forwards rejected async handlers here automatically. Client errors (malformed
// JSON, an oversized body, an AppError) keep their 4xx; everything else is an
// unexpected 500 and is captured to Sentry.
app.use((err: unknown, req: Request, res: Response, _next: NextFunction) => {
  const url = req.url?.split("?")[0];
  const clientStatus = clientErrorStatus(err);
  if (clientStatus === undefined) {
    logger.error({ err, url }, "unhandled error");
    captureServerError(err, { req });
  } else {
    logger.warn({ status: clientStatus, url }, "rejected request");
  }
  if (res.headersSent) return;
  if (clientStatus === undefined) {
    res.status(500).json({ error: "Internal server error" });
  } else {
    const message = err instanceof AppError ? err.message : (STATUS_CODES[clientStatus] ?? "Bad request");
    res.status(clientStatus).json({ error: message });
  }
});

export default app;
