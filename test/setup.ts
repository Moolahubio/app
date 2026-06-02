import { readFileSync } from "node:fs";

// Load .env into process.env before any module (db.ts, crypto.ts) is imported.
try {
  for (const line of readFileSync(".env", "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z_]+)\s*=\s*"?([^"]*)"?\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
  }
} catch {
  /* env may be provided by the environment (CI) */
}

// Sensible defaults so tests run even without a full .env.
process.env.APP_ENCRYPTION_KEY ||= "0".repeat(64);
process.env.STELLAR_NETWORK ||= "testnet";
