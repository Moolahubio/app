import type { Request, Response, NextFunction } from "express";

/**
 * Build a set of allowed browser origins for credentialed/CSRF-sensitive
 * requests. Sources (all optional, de-duplicated):
 *  - ALLOWED_ORIGINS: comma-separated full origins or bare hosts (manual escape
 *    hatch for extra cross-origin clients).
 *  - REPLIT_DOMAINS: the domain(s) this server is actually served on. Set
 *    automatically by Replit in both dev and deployment, so the origin the app
 *    runs under is always trusted without any manual configuration.
 *
 * Bare hosts (no scheme) are normalized to https://.
 */
/**
 * Strip trailing slashes in linear time. Equivalent to `.replace(/\/+$/, "")`
 * but without that pattern's quadratic backtracking on a long run of slashes —
 * `isAllowedOrigin` runs this on the attacker-controlled Origin header, where
 * the backtracking is a ReDoS / event-loop-starvation DoS vector.
 */
function stripTrailingSlashes(s: string): string {
  let end = s.length;
  while (end > 0 && s.charCodeAt(end - 1) === 47 /* "/" */) end--;
  return s.slice(0, end);
}

function originsFromCsv(csv: string | undefined): string[] {
  return (csv || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((s) => (/^https?:\/\//i.test(s) ? s : `https://${s}`))
    .map(stripTrailingSlashes);
}

export function getAllowedOrigins(): string[] {
  return Array.from(
    new Set([
      ...originsFromCsv(process.env.ALLOWED_ORIGINS),
      ...originsFromCsv(process.env.REPLIT_DOMAINS),
    ]),
  );
}

export function isAllowedOrigin(origin: string | undefined | null): boolean {
  if (!origin) return true; // no Origin header => same-origin / non-browser
  // No legitimate origin is anywhere near this long; reject early so a
  // pathological Origin header can't burn CPU during normalization/lookup.
  if (origin.length > 2048) return false;
  return getAllowedOrigins().includes(stripTrailingSlashes(origin));
}

/**
 * Middleware that rejects requests whose Origin header is cross-origin and not
 * in the allow-list. Unlike requireJsonAndAllowedOrigin, it does NOT require a
 * JSON Content-Type, so it is suitable for authenticated state-changing routes
 * that carry no request body (e.g. logout, 2FA setup, account deactivation).
 *
 * Requests without an Origin header are always passed through: non-browser
 * clients (curl, server-to-server) don't send Origin, and same-origin browser
 * requests are handled correctly by isSameOrigin().
 */
export function requireAllowedOrigin(req: Request, res: Response, next: NextFunction): void {
  const origin = req.headers["origin"];
  if (origin && !isSameOrigin(req) && !isAllowedOrigin(origin)) {
    res.status(403).json({ error: "Forbidden" });
    return;
  }
  next();
}

/**
 * True when the request's Origin matches the host the request was served on
 * (standard same-origin CSRF check). Honors X-Forwarded-Host so it works behind
 * the Replit reverse proxy, where the API and frontend share one origin.
 */
export function isSameOrigin(req: Request): boolean {
  const origin = req.headers["origin"];
  if (!origin) return true; // no Origin header => same-origin / non-browser
  const forwardedHost = (req.headers["x-forwarded-host"] as string | undefined)
    ?.split(",")[0]
    ?.trim();
  const host = forwardedHost || req.headers["host"];
  if (!host) return false;
  // Strict same-origin is scheme+host(+port). Behind the Replit proxy the public
  // scheme is https (surfaced via x-forwarded-proto), even though the upstream
  // connection to this server is plain http.
  const forwardedProto = (req.headers["x-forwarded-proto"] as string | undefined)
    ?.split(",")[0]
    ?.trim();
  const proto = forwardedProto || req.protocol;
  try {
    const o = new URL(origin);
    return o.host === host && o.protocol === `${proto}:`;
  } catch {
    return false;
  }
}
