import { defineConfig } from "drizzle-kit";
import path from "path";
import { sslFor } from "./src/connection";

// Migrations run as the table owner (Supabase `postgres`, via the session
// pooler), never as the app role, which has no DDL rights. MIGRATIONS_DATABASE_URL
// lives in the protected GitHub environment only; DATABASE_URL is the fallback
// for local databases. `generate` and `check` work from the schema alone.
const url = process.env.MIGRATIONS_DATABASE_URL || process.env.DATABASE_URL;
const offline = process.argv.some((a) => a === "generate" || a === "check");
if (!url && !offline) {
  throw new Error("MIGRATIONS_DATABASE_URL or DATABASE_URL must be set");
}

// drizzle-kit only takes a TLS object alongside discrete credentials, so a
// remote URL is split up; a local URL stays plain (see sslFor).
function credentials(raw: string) {
  const ssl = sslFor(raw, process.env.PG_CA_CERT);
  if (ssl === false) return { url: raw };
  const u = new URL(raw);
  return {
    host: u.hostname,
    port: u.port ? Number(u.port) : 5432,
    user: decodeURIComponent(u.username),
    password: decodeURIComponent(u.password),
    database: decodeURIComponent(u.pathname.slice(1)) || "postgres",
    ssl,
  };
}

export default defineConfig({
  schema: path.join(__dirname, "./src/schema/index.ts"),
  // Relative to lib/db (scripts run there); drizzle-kit mis-joins absolute paths.
  out: "./migrations",
  dialect: "postgresql",
  ...(url ? { dbCredentials: credentials(url) } : {}),
});
