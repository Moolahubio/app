#!/usr/bin/env node
/**
 * CI ban list for the API and the shared libraries (docs/privy-account-layer.md
 * §4, "CI ban list"; extends docs/base-build-spec-v2.md §2.2). Pure Node, no
 * dependencies. It fails when code under artifacts/api-server/** or lib/**
 * (scripts included) uses:
 *  - a Privy user-token or signer API: user_jwts, authorization_context,
 *    authorizationContext, authorization_private_keys, verifyAuthToken,
 *    verifyAccessToken, wallets/authenticate, getTestAccessToken, addSigners;
 *  - a local signing key: privateKeyToAccount, or any import from viem/accounts;
 *  - a private key from the environment: process.env.X_PRIVATE_KEY or
 *    process.env["X_PRIVATE_KEY"].
 *
 * Today's testnet code still does some of this until P2 deletes it. LEGACY
 * lists those files with the most uses each may keep, so a new use anywhere,
 * a legacy file included, fails at once. P2 empties LEGACY.
 *
 * Usage:
 *   node scripts/check-api-ban-list.mjs           tracked and new files under the scanned paths
 *   node scripts/check-api-ban-list.mjs FILE...   the named files, wherever they are (a self-test)
 * Prints file:line and the rule. Exits 1 on any finding, 2 on a usage error.
 */
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { relative, resolve } from "node:path";

const CALLER_CWD = process.cwd();
const top = spawnSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" });
if (top.status !== 0) {
  process.stderr.write(`check-api-ban-list: not in a git checkout: ${top.stderr}`);
  process.exit(2);
}
const ROOT = top.stdout.trim();
process.chdir(ROOT);

const SCANNED = ["artifacts/api-server/", "lib/"];
const CODE = /\.(?:[cm]?[jt]sx?)$/;
const SKIP = /(?:^|\/)(?:node_modules|dist|build|\.cache)\//;

const RULES = [
  {
    id: "privy-user-token-or-signer",
    re: /\b(?:user_jwts|authorization_context|authorizationContext|authorization_private_keys|verifyAuthToken|verifyAccessToken|getTestAccessToken|addSigners)\b|wallets\/authenticate/g,
  },
  { id: "local-signing-key", re: /\bprivateKeyToAccount\b|["'`]viem\/accounts["'`]/g },
  { id: "private-key-env", re: /\bprocess\.env(?:\.[A-Z0-9_]*PRIVATE_KEY\b|\[\s*["'`][A-Z0-9_]*PRIVATE_KEY["'`]\s*\])/g },
];

// Today's testnet code, deleted in P2 (docs/privy-account-layer.md §4): path ->
// rule -> the most uses it may keep. The e2e tests only delete the variable, so
// the key is never set while they run.
const E2E_DELETES_KEY = { "private-key-env": 1 };
const LEGACY = {
  "artifacts/api-server/src/lib/chain.ts": { "local-signing-key": 11, "private-key-env": 1 },
  "artifacts/api-server/src/lib/circleChain.ts": { "local-signing-key": 3, "private-key-env": 1 },
  "artifacts/api-server/src/lib/settlement.ts": { "private-key-env": 1 },
  "artifacts/api-server/src/lib/privy.ts": { "privy-user-token-or-signer": 1 },
  "artifacts/api-server/scripts/set-fee-sink.mjs": { "local-signing-key": 3, "private-key-env": 1 },
  ...Object.fromEntries(
    [
      "account-delete-http", "auth-http", "circles-accumulation", "circles-http-authz", "circles-http",
      "circles-invite-authz", "circles", "goals-race", "home-data-http", "native-session-http",
      "password-reset-http", "password-reset-throttle-http", "profile-timezone-http", "referrals",
      "stepup-http", "twofactor-http",
    ].map((name) => [`artifacts/api-server/src/lib/${name}.e2e.ts`, E2E_DELETES_KEY]),
  ),
};

function scan(path) {
  const counts = {};
  const hits = [];
  readFileSync(path, "utf8")
    .split("\n")
    .forEach((line, i) => {
      for (const rule of RULES) {
        rule.re.lastIndex = 0;
        for (const _ of line.matchAll(rule.re)) {
          counts[rule.id] = (counts[rule.id] ?? 0) + 1;
          hits.push({ line: i + 1, rule: rule.id });
        }
      }
    });
  const allowed = LEGACY[path] ?? {};
  return hits.filter((h) => counts[h.rule] > (allowed[h.rule] ?? 0)).map((h) => `${path}:${h.line}  ${h.rule}`);
}

const args = process.argv.slice(2);
if (args.some((a) => a.startsWith("-"))) {
  process.stderr.write("usage: node scripts/check-api-ban-list.mjs [FILE...]\n");
  process.exit(2);
}

let files;
if (args.length) {
  files = args.map((a) => relative(ROOT, resolve(CALLER_CWD, a)));
  for (const f of files) {
    if (!existsSync(f) || !statSync(f).isFile()) {
      process.stderr.write(`check-api-ban-list: no such file: ${f}\n`);
      process.exit(2);
    }
  }
} else {
  const ls = spawnSync("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", ...SCANNED], {
    encoding: "utf8",
    maxBuffer: 1 << 28,
  });
  if (ls.status !== 0) {
    process.stderr.write(`check-api-ban-list: git ls-files failed: ${ls.stderr}`);
    process.exit(2);
  }
  files = [...new Set(ls.stdout.split("\0").filter(Boolean))].filter((f) => CODE.test(f) && !SKIP.test(f) && existsSync(f));
}

const findings = files.flatMap(scan);
for (const f of findings) console.log(f);
if (findings.length) {
  console.error(
    `check-api-ban-list: ${findings.length} finding(s). The API never checks a Privy user token, never adds a ` +
      "signer and never holds a signing key (docs/privy-account-layer.md §3.1, §4).",
  );
  process.exit(1);
}
console.log(`check-api-ban-list: ok (${files.length} files)`);
