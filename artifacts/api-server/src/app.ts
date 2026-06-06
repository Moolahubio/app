import express, { type Express, type Request, type Response, type NextFunction } from "express";
import cors from "cors";
import helmet from "helmet";
import rateLimit from "express-rate-limit";
import cookieParser from "cookie-parser";
import pinoHttp from "pino-http";
import router from "./routes";
import { logger } from "./lib/logger";

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
        return { id: req.id, method: req.method, url: req.url?.split("?")[0] };
      },
      res(res) {
        return { statusCode: res.statusCode };
      },
    },
  }),
);

// Security headers (CSP, HSTS, X-Content-Type-Options, frameguard, etc.).
app.use(helmet());

// CORS: only allow credentialed requests from explicitly allowlisted origins
// (ALLOWED_ORIGINS, comma-separated). Requests with no Origin header
// (same-origin, server-to-server, health checks) are allowed. Never reflect an
// arbitrary origin while credentials are enabled.
const allowedOrigins = (process.env.ALLOWED_ORIGINS || "")
  .split(",")
  .map((o) => o.trim())
  .filter(Boolean);
app.use(
  cors({
    origin(origin, cb) {
      if (!origin || allowedOrigins.includes(origin)) return cb(null, true);
      // Don't throw — just omit CORS headers so the browser blocks it.
      return cb(null, false);
    },
    credentials: true,
  }),
);

app.use(cookieParser());
app.use(express.json({ limit: "1mb" }));
app.use(express.urlencoded({ extended: true, limit: "1mb" }));

// Rate limiting (per IP). Auth endpoints get a much tighter budget to blunt
// credential stuffing / brute force.
const apiLimiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 300, standardHeaders: true, legacyHeaders: false });
const authLimiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 20, standardHeaders: true, legacyHeaders: false });
app.use("/api/auth", authLimiter);
app.use("/api", apiLimiter);

app.use("/api", router);

// 404 for unmatched API routes.
app.use((_req: Request, res: Response) => {
  res.status(404).json({ error: "Not found" });
});

// Global error handler (last middleware). Logs the full error server-side and
// returns a generic message; never leaks stack traces or internals. Express 5
// forwards rejected async handlers here automatically.
app.use((err: unknown, req: Request, res: Response, _next: NextFunction) => {
  logger.error({ err, url: req.url?.split("?")[0] }, "unhandled error");
  if (res.headersSent) return;
  res.status(500).json({ error: "Internal server error" });
});

export default app;
