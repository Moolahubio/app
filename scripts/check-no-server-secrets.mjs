#!/usr/bin/env node
/**
 * Build check: no server secret reaches the iOS app or the website
 * (docs/privy-account-layer.md §2 and invariant 5). Pure Node, no dependencies.
 *
 * Fails when
 *  1. apps/ios/**, artifacts/moolahub-app/src/** or the built
 *     artifacts/moolahub-app/dist/public names a server secret (BANNED below)
 *     or holds a PEM "-----BEGIN" header;
 *  2. a VITE_ variable carries a secret name (anything VITE_ is compiled into
 *     the public bundle);
 *  3. vite.config.ts compiles a server secret into the bundle through `define`,
 *     or widens `envPrefix` beyond VITE_.
 * Mentions in the iOS docs (*.md) are reported only when they are a "-----BEGIN"
 * header, since a doc may explain which names stay on the server.
 *
 * These rules see names, not values: Vite replaces import.meta.env.X with the
 * value, so a leaked value carries no name. CI therefore also builds the web
 * app with a canary value in every server secret name and fails if one reaches
 * dist/public (.github/workflows/secret-scan.yml, bundle job).
 *
 * Usage: node scripts/check-no-server-secrets.mjs [--require-dist]
 *   --require-dist  also fail when dist/public is missing (CI, after a build)
 * Prints file:line and the rule, never a value. Exits 1 on any finding.
 */
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(fileURLToPath(new URL(".", import.meta.url)), "..");
const WEB = "artifacts/moolahub-app";
const DIST = `${WEB}/dist/public`;

// Server-only names. \b keeps public neighbours apart (APNS_KEY_ID, PRIVY_APP_ID).
const BANNED = [
  "PRIVY_APP_SECRET",
  "PRIVY_APP_SECRET_READONLY",
  "PRIVY_WEBHOOK_SECRET",
  "DATABASE_URL",
  "MIGRATIONS_DATABASE_URL",
  "APP_ENCRYPTION_KEY",
  "OPERATOR_TOKEN",
  "RESEND_API_KEY",
  "APNS_KEY",
  "SENTRY_AUTH_TOKEN",
];
const BANNED_RE = new RegExp(`\\b(?:${BANNED.join("|")}|[A-Z0-9_]*PRIVATE_KEY)\\b`);
const PEM_RE = /-----BEGIN/;
// A VITE_ name that is, or looks like, a secret: an API key (VITE_ETHERSCAN_API_KEY)
// and an RPC URL, which carries the provider's key, included.
const VITE_SECRET_RE = new RegExp(
  `\\bVITE_(?:[A-Z0-9_]*_)?(?:${BANNED.join("|")}|[A-Z0-9_]*(?:SECRET|PRIVATE_KEY|PASSWORD|AUTH_TOKEN|API_KEY|RPC_URL))\\b`,
);

const SKIP_DIRS = new Set(["node_modules", ".git", "dist", "build", "DerivedData", ".build", "xcuserdata", ".swiftpm", "Pods"]);
const findings = [];

function* walk(dir, skipDirs = SKIP_DIRS) {
  if (!existsSync(dir)) return;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (!skipDirs.has(entry.name)) yield* walk(p, skipDirs);
    } else if (entry.isFile()) {
      yield p;
    }
  }
}

function textLines(file) {
  if (statSync(file).size > 20_000_000) return null;
  const buf = readFileSync(file);
  if (buf.subarray(0, 8000).includes(0)) return null; // binary
  return buf.toString("utf8").split("\n");
}

function report(file, line, rule) {
  findings.push(`${relative(ROOT, file)}:${line}  ${rule}`);
}

/** Rules 1 and 2 over every text file under `dir`. */
function scanTree(dir, { docsNamesOk = false, skipDirs } = {}) {
  for (const file of walk(join(ROOT, dir), skipDirs)) {
    const lines = textLines(file);
    if (!lines) continue;
    const isDoc = /\.md$/i.test(file);
    lines.forEach((text, i) => {
      if (PEM_RE.test(text)) report(file, i + 1, "pem-header");
      if (VITE_SECRET_RE.test(text)) report(file, i + 1, "vite-secret-name");
      else if (BANNED_RE.test(text) && !(docsNamesOk && isDoc)) report(file, i + 1, "server-secret-name");
    });
  }
}

scanTree("apps/ios", { docsNamesOk: true });
scanTree(`${WEB}/src`);

// Rule 2 also covers the web package's own config and the env examples.
for (const file of [`${WEB}/.env.example`, `${WEB}/index.html`, `${WEB}/vite.config.ts`, ".env.example", ".replit"]) {
  const path = join(ROOT, file);
  if (!existsSync(path)) continue;
  textLines(path)?.forEach((text, i) => {
    if (VITE_SECRET_RE.test(text)) report(path, i + 1, "vite-secret-name");
  });
}

// Rule 3: what vite.config.ts compiles in through `define`, and envPrefix.
{
  const path = join(ROOT, WEB, "vite.config.ts");
  const src = readFileSync(path, "utf8");
  const start = src.search(/\bdefine\s*:\s*\{/);
  if (start >= 0) {
    let depth = 0;
    let end = src.indexOf("{", start);
    for (; end < src.length; end++) {
      if (src[end] === "{") depth++;
      else if (src[end] === "}" && --depth === 0) break;
    }
    const block = src.slice(start, end + 1);
    const firstLine = src.slice(0, start).split("\n").length;
    block.split("\n").forEach((text, i) => {
      if (BANNED_RE.test(text) || /SECRET|PASSWORD/.test(text)) report(path, firstLine + i, "define-server-secret");
    });
  }
  src.split("\n").forEach((text, i) => {
    if (/\benvPrefix\b/.test(text)) report(path, i + 1, "env-prefix-widened");
  });
}

// Rule 1 over the built bundle, third-party code included.
const dist = join(ROOT, DIST);
if (existsSync(dist)) {
  scanTree(DIST, { skipDirs: new Set() });
} else if (process.argv.includes("--require-dist")) {
  findings.push(`${DIST}  missing: build the web app first`);
}

for (const f of findings) console.log(f);
if (findings.length) {
  console.error(
    `check-no-server-secrets: ${findings.length} finding(s). Server secrets stay on the server: ` +
      "never in apps/ios, the web sources, the web bundle or a VITE_ name.",
  );
  process.exit(1);
}
console.log(`check-no-server-secrets: ok (apps/ios, ${WEB}/src${existsSync(dist) ? `, ${DIST}` : ""})`);
