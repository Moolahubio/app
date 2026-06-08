import type { Request } from "express";

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
function originsFromCsv(csv: string | undefined): string[] {
  return (csv || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((s) => (/^https?:\/\//i.test(s) ? s : `https://${s}`))
    .map((s) => s.replace(/\/+$/, ""));
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
  return getAllowedOrigins().includes(origin.replace(/\/+$/, ""));
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
