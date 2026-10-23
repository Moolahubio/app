import type { ConnectionOptions } from "node:tls";

const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "::1", "[::1]"]);

/**
 * TLS settings for a Postgres URL, shared by the app pool and drizzle-kit.
 *
 * pg parses `connectionString` and merges it OVER the config object, so any
 * `ssl*` parameter in the URL silently overrides the `ssl` option (and
 * pg-connection-string treats `sslmode=require` as verify-full against the
 * system CAs, which Supabase's own CA fails). TLS therefore comes from env vars
 * only, and a URL that carries TLS parameters is rejected outright.
 *
 * - `PG_CA_CERT` set (PEM; literal `\n` escapes allowed): verify-full against
 *   that CA. This is the Supabase path.
 * - unset, remote host: verify-full against the system trust store.
 * - unset, local host or unix socket: no TLS, for dev databases and CI.
 */
export function sslFor(url: string, caPem: string | undefined): false | ConnectionOptions {
  if (/[?&](ssl[a-z]*|uselibpqcompat)=/i.test(url)) {
    throw new Error("Database URLs must not carry ssl* parameters; set PG_CA_CERT instead (see .env.example)");
  }
  const ca = caPem?.trim() ? caPem.replace(/\\n/g, "\n") : undefined;
  if (ca) return { ca, rejectUnauthorized: true };
  let host: string;
  try {
    host = new URL(url).hostname;
  } catch {
    throw new Error("Database URL is not a valid postgres:// URL");
  }
  // An empty host means a unix socket (postgres:///db?host=/tmp).
  if (host === "" || LOCAL_HOSTS.has(host)) return false;
  return { rejectUnauthorized: true };
}

/** True for a localhost/loopback host or a unix socket: dev and CI databases only. */
export function isLocalDatabaseUrl(url: string): boolean {
  try {
    const host = new URL(url).hostname;
    return host === "" || LOCAL_HOSTS.has(host);
  } catch {
    return false;
  }
}

/** `PG_POOL_MAX`, defaulting to 5 (sized for Supabase's transaction pooler). */
export function poolMaxFrom(raw: string | undefined): number {
  if (raw === undefined || raw === "") return 5;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1) throw new Error(`Invalid PG_POOL_MAX value: "${raw}"`);
  return n;
}
