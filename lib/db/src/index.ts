import { drizzle } from "drizzle-orm/node-postgres";
import pg from "pg";
import * as schema from "./schema";
import { poolMaxFrom, sslFor } from "./connection";

const { Pool } = pg;

const connectionString = process.env.DATABASE_URL;
if (!connectionString) {
  throw new Error(
    "DATABASE_URL must be set. Did you forget to provision a database?",
  );
}

// Sized for Supabase's transaction pooler: a few connections per instance,
// recycled often, and quick to give up rather than queue requests behind a dead
// backend. Statement and lock timeouts are set on the app role (migration 0002),
// not here, because the transaction pooler doesn't keep session settings.
export const pool = new Pool({
  connectionString,
  ssl: sslFor(connectionString, process.env.PG_CA_CERT),
  max: poolMaxFrom(process.env.PG_POOL_MAX),
  connectionTimeoutMillis: 5_000,
  idleTimeoutMillis: 10_000,
  maxLifetimeSeconds: 900,
});

// An idle client can error when the pooler restarts. With no listener that
// error is thrown on the pool and crashes the process; the pool already drops
// the broken client, so logging is all that's needed.
pool.on("error", (err) => {
  console.error(`[db] idle client error: ${err.message}`);
});

let ending: Promise<void> | undefined;

/**
 * Close every pooled connection once, after checked-out clients are released.
 * The API calls this from its SIGTERM handler once the HTTP server has stopped
 * taking requests, so a deploy or scale-down doesn't strand sessions on the
 * pooler. Safe to call more than once.
 */
export function endPool(): Promise<void> {
  ending ??= pool.end().catch((err: Error) => {
    console.error(`[db] pool shutdown failed: ${err.message}`);
  });
  return ending;
}

// Graceful default for any process using the pool (scripts, tests, a worker):
// on SIGTERM, release connections and exit. When the host app has its own
// SIGTERM handler (the API drains HTTP first, then calls endPool), defer to it.
process.once("SIGTERM", () => {
  if (process.listenerCount("SIGTERM") > 0) return;
  void endPool().finally(() => process.exit(143));
});

export const db = drizzle(pool, { schema });

export * from "./schema";
