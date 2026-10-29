#!/usr/bin/env node
/**
 * Dependency-free secret scanner, the fallback for machines without gitleaks
 * (docs/privy-account-layer.md §2, "Keeping secrets out of git"). gitleaks in CI
 * (.github/workflows/secret-scan.yml) is the control that enforces; this one
 * catches the common cases before a commit and runs in CI as a second opinion.
 *
 * It never prints a value: a finding is `path:line  rule`. The history mode adds
 * a mask (first 3 characters and the length) and an 8-hex fingerprint of the
 * value's SHA-256, so two findings of the same value can be matched up.
 *
 * Allowlists are read from the [[allowlists]] tables of .gitleaks.toml (paths,
 * regexes, regexTarget, condition, targetRules), so both scanners skip the same
 * known test literals.
 *
 * Usage:
 *   node scripts/secret-scan.mjs              every tracked file in the working tree
 *   node scripts/secret-scan.mjs --staged     lines added in the staged changes (pre-commit)
 *   node scripts/secret-scan.mjs FILE...      the named files, relative to the current directory
 *   node scripts/secret-scan.mjs --history    lines added by every commit on every ref
 * Exits 1 when anything is found, 2 on a usage or git error or a named file that
 * does not exist.
 */
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import { relative, resolve } from "node:path";
import { createInterface } from "node:readline";

// Named files are resolved against the directory the script was run from.
const CALLER_CWD = process.cwd();
const ROOT = git(["rev-parse", "--show-toplevel"]).trim();
process.chdir(ROOT);

// ---------------------------------------------------------------------------
// Rules. Ids follow gitleaks' rule ids (its defaults and the custom rules in
// .gitleaks.toml), so an allowlist's targetRules means the same in both.
// ---------------------------------------------------------------------------

// A 64-hex value is not a key when the text before it on its line (the name
// it is assigned to, a keccak256( call, a vm.store( slot), its Markdown table
// header, or an expression left open on the line before (`bytes32 X_HASH =`)
// names a checksum or hash. A comment after the value ("# not a tx hash") and
// a finished line before it (CREATE2_SALT=0x…) do not count.
const CHECKSUM_NAME = /sha-?256|checksum|digest|integrity|hash|keccak|bytes32|merkle|salt|topic|selector|slot|vm\.(?:store|load)\(/i;
const OPEN_EXPRESSION = /[=(,:]\s*$/;
// Files made of hashes (lockfiles, deployment and gas snapshots).
const CHECKSUM_FILES = /(^|\/)(pnpm-lock\.yaml|uv\.lock|package-lock\.json|Package\.resolved|\.gas-snapshot)$|^contracts\/(deployments|snapshots|broadcast)\//;
// Local-only or placeholder hosts in URLs, the compose `db` service included.
const URL_PLACEHOLDER = /^(localhost|127\.0\.0\.1|\[::1\]|0\.0\.0\.0|db|[^/:]+\.(local|localhost|test|example|invalid)|example\.(com|org))(:\d+)?([/?#]|$)/i;
// A password that is wholly a placeholder: ${VAR}, $VAR, <password>, ***, or a stock word.
const PASSWORD_PLACEHOLDER = /^(\$\{[^}]*\}|\$[A-Za-z_]\w*|<[^>]*>|\{[^}]*\}|\*+|password|pass|secret|postgres|user|xxx+|changeme)$/i;
// This project's server secrets, by name (artifacts/api-server/.env.example).
const SECRET_NAME =
  "PRIVY_APP_SECRET(?:_READONLY)?|PRIVY_WEBHOOK_SECRET|APP_ENCRYPTION_KEY|OPERATOR_TOKEN|RESEND_API_KEY|APNS_KEY|SENTRY_AUTH_TOKEN|SESSION_SECRET|ETHERSCAN_API_KEY|[A-Z0-9_]*PRIVATE_KEY";
// A reference or a placeholder, not a value: $VAR, ${{ secrets.X }}, <key>,
// process.env.X, a function call, a bare word with no digit, 0xYOUR_KEY, 0x...
const VALUE_REFERENCE = /^(?:[$<{[]|process\.|env\.|import\.|secrets\.|vars\.)|\(|^[A-Za-z_.]+$|[<>{}$]|\.\.\.|your|x{3,}|placeholder|changeme|example/i;

function hexIsChecksum(line, m, ctx) {
  return (
    CHECKSUM_NAME.test(line.slice(0, m.index)) ||
    CHECKSUM_NAME.test(ctx.header) ||
    (OPEN_EXPRESSION.test(ctx.prev) && CHECKSUM_NAME.test(ctx.prev))
  );
}

const RULES = [
  { id: "private-key", re: /-----BEGIN[ A-Z0-9_-]{0,100}PRIVATE KEY( BLOCK)?-----/g },
  // Privy: app secrets and authorization keys (docs.privy.io security checklist).
  { id: "privy-app-secret", re: /privy_app_secret_[A-Za-z0-9]{16,}/g },
  { id: "privy-authorization-key", re: /wallet-(?:auth|api):[A-Za-z0-9+/]{16,}={0,2}/g },
  // A P-256 private key body (PKCS#8, base64) without PEM lines: an unprefixed
  // Privy authorization key or an APNs .p8 key.
  { id: "p256-private-key", re: /MIG[HT]AgEAMBMGByqGSM49AgEGCCqGSM49AwEHB[A-Za-z0-9+/=]{20,}/g },
  {
    id: "evm-private-key",
    re: /(?<![0-9A-Za-z])(?:0x)?[0-9a-fA-F]{64}(?![0-9A-Za-z])/g,
    skip: (value, line, path, m, ctx) =>
      hexIsChecksum(line, m, ctx) ||
      CHECKSUM_FILES.test(path) ||
      /^\d+$/.test(value) || // a 64-digit decimal number
      new Set(value.replace(/^0x/, "").toLowerCase()).size < 6,
  },
  {
    id: "moolahub-secret-assignment",
    re: new RegExp(`\\b(?:${SECRET_NAME})\\b["']?\\s*[:=]\\s*["'\`]?([^\\s"'\`#,;]{8,})`, "g"),
    // A run of one character (a CI dummy such as 64 zeros) is not a secret either.
    skip: (value) => VALUE_REFERENCE.test(value) || new Set(value.replace(/^0x/, "").toLowerCase()).size < 6,
  },
  // An RPC URL that carries the provider's key in its path.
  {
    id: "rpc-url-key",
    re: /(?:alchemy\.com\/v2|infura\.io\/v3|quiknode\.pro|api\.developer\.coinbase\.com\/rpc\/v1\/[a-z0-9-]+)\/([A-Za-z0-9_-]{16,})/gi,
    skip: (value) => /your|api_?key|x{4}/i.test(value),
  },
  // Resend API keys start with re_ (format not verified against Resend's docs).
  { id: "resend-api-key", re: /\bre_[A-Za-z0-9_]{20,}\b/g, skip: (value) => !/\d/.test(value) || !/[A-Z]/.test(value) },
  { id: "sentry-org-token", re: /\bsntry[su]_[A-Za-z0-9+/=_-]{20,}/g },
  { id: "aws-access-token", re: /\b(?:AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}\b/g },
  { id: "aws-secret-key", re: /aws_?secret_?access_?key["']?\s*[:=]\s*["']?[A-Za-z0-9/+]{40}(?![A-Za-z0-9/+])/gi },
  { id: "gcp-api-key", re: /\bAIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])/g },
  { id: "google-oauth-client-secret", re: /\bGOCSPX-[0-9A-Za-z_-]{28}(?![0-9A-Za-z_-])/g },
  { id: "stripe-access-token", re: /\b(?:sk|rk)_(?:live|test)_[0-9A-Za-z]{10,}/g },
  { id: "stripe-webhook-secret", re: /\bwhsec_[0-9A-Za-z+/=]{20,}/g },
  { id: "github-token", re: /\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})/g },
  { id: "slack-token", re: /\bxox[abeoprs]-[A-Za-z0-9-]{10,}/g },
  { id: "slack-webhook-url", re: /https:\/\/hooks\.slack\.com\/(?:services|workflows|triggers)\/[A-Za-z0-9+/_-]{20,}/g },
  { id: "jwt", re: /\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g },
  {
    id: "url-credentials",
    re: /\b[a-z][a-z0-9+.-]{1,20}:\/\/[^\s/:@'"`]{1,100}:([^\s/@'"`]{1,200})@([^\s'"`]+)/gi,
    skip: (_value, _line, _path, m) => PASSWORD_PLACEHOLDER.test(m[1]) || URL_PLACEHOLDER.test(m[2]),
  },
];

// ---------------------------------------------------------------------------
// Allowlists from .gitleaks.toml (the subset of TOML that file uses).
// ---------------------------------------------------------------------------

function readAllowlists() {
  if (!existsSync(".gitleaks.toml")) return [];
  const src = readFileSync(".gitleaks.toml", "utf8");
  const lists = [];
  let current = null;
  let i = 0;
  const readString = () => {
    for (const q of ["'''", '"""', "'", '"']) {
      if (!src.startsWith(q, i)) continue;
      const end = src.indexOf(q, i + q.length);
      if (end < 0) throw new Error(".gitleaks.toml: unterminated string");
      const raw = src.slice(i + q.length, end);
      i = end + q.length;
      return q === '"' ? JSON.parse(`"${raw}"`) : raw;
    }
    throw new Error(`.gitleaks.toml: expected a string at offset ${i}`);
  };
  const skipBlank = () => {
    while (i < src.length) {
      if (/\s|,/.test(src[i])) i++;
      else if (src[i] === "#") while (i < src.length && src[i] !== "\n") i++;
      else break;
    }
  };
  while (i < src.length) {
    skipBlank();
    if (i >= src.length) break;
    if (src[i] === "[") {
      const end = src.indexOf("\n", i);
      const header = src.slice(i, end < 0 ? src.length : end).replace(/#.*/, "").trim();
      current = header === "[[allowlists]]" ? {} : null;
      if (current) lists.push(current);
      i = end < 0 ? src.length : end;
      continue;
    }
    const key = /^[A-Za-z_][\w.-]*/.exec(src.slice(i))?.[0];
    if (!key) throw new Error(`.gitleaks.toml: cannot parse near offset ${i}`);
    i += key.length;
    skipBlank();
    if (src[i] !== "=") throw new Error(`.gitleaks.toml: expected = after ${key}`);
    i++;
    skipBlank();
    let value;
    if (src[i] === "[") {
      i++;
      value = [];
      for (skipBlank(); src[i] !== "]"; skipBlank()) value.push(readString());
      i++;
    } else if (/['"]/.test(src[i])) {
      value = readString();
    } else {
      const end = src.slice(i).search(/[\s#]/);
      value = src.slice(i, end < 0 ? src.length : i + end);
      i += value.length;
    }
    if (current) current[key] = value;
  }
  const toRe = (s) => (s.startsWith("(?i)") ? new RegExp(s.slice(4), "i") : new RegExp(s));
  return lists.map((a) => ({
    and: String(a.condition ?? "OR").toUpperCase() === "AND",
    paths: (a.paths ?? []).map(toRe),
    regexes: (a.regexes ?? []).map(toRe),
    target: a.regexTarget ?? "secret",
    rules: a.targetRules ?? null,
  }));
}

const ALLOWLISTS = readAllowlists();

function allowed(f) {
  return ALLOWLISTS.some((a) => {
    if (a.rules && !a.rules.includes(f.rule)) return false;
    const subject = a.target === "line" ? f.line : a.target === "match" ? f.match : f.value;
    const checks = [];
    if (a.paths.length) checks.push(a.paths.some((re) => re.test(f.path)));
    if (a.regexes.length) checks.push(a.regexes.some((re) => re.test(subject)));
    if (!checks.length) return false;
    return a.and ? checks.every(Boolean) : checks.some(Boolean);
  });
}

// ---------------------------------------------------------------------------
// Scanning
// ---------------------------------------------------------------------------

/** The line before and the current Markdown table header, for the checksum context. */
function contextTracker() {
  let prev = "";
  let header = "";
  return (line) => {
    const ctx = { prev, header };
    if (/^\s*\|[\s|:-]+\|\s*$/.test(line)) header = prev;
    else if (!/^\s*\|/.test(line)) header = "";
    prev = line;
    return ctx;
  };
}

function scanLine(path, lineNo, line, out, ctx, extra = {}) {
  if (line.length > 20_000) line = line.slice(0, 20_000);
  for (const rule of RULES) {
    rule.re.lastIndex = 0;
    for (const m of line.matchAll(rule.re)) {
      const value = m[1] ?? m[0];
      if (rule.skip?.(value, line, path, m, ctx)) continue;
      const f = { path, lineNo, rule: rule.id, value, match: m[0], line, ...extra };
      if (!allowed(f)) out.push(f);
    }
  }
}

function git(args, opts = {}) {
  const r = spawnSync("git", args, { encoding: "utf8", maxBuffer: 1 << 30, ...opts });
  if (r.status !== 0) {
    process.stderr.write(`secret-scan: git ${args[0]} failed: ${r.stderr}`);
    process.exit(2);
  }
  return r.stdout;
}

function isBinary(buf) {
  return buf.subarray(0, 8000).includes(0);
}

/** `named`: the user named these files, so a missing one is an error, not a file deleted in the working tree. */
function scanFiles(paths, { named = false } = {}) {
  const out = [];
  for (const path of paths) {
    let st;
    try {
      st = statSync(path);
    } catch {
      if (!named) continue; // deleted in the working tree
      process.stderr.write(`secret-scan: no such file: ${path}\n`);
      process.exit(2);
    }
    if (!st.isFile() || st.size > 5_000_000) continue;
    const buf = readFileSync(path);
    if (isBinary(buf)) continue;
    const track = contextTracker();
    buf.toString("utf8").split("\n").forEach((line, i) => scanLine(path, i + 1, line, out, track(line)));
  }
  return out;
}

/** Feeds a unified diff (git diff / git log -p) line by line into scanLine: added lines only. */
function diffScanner(out) {
  let path = null;
  let lineNo = 0;
  let commit = null;
  let inHeader = false; // between "diff --git" and the first "@@", where "+++ b/path" names the file
  let track = contextTracker();
  return (raw) => {
    if (raw.startsWith("commit:")) {
      commit = raw.slice(7, 19);
      path = null;
      inHeader = false;
    } else if (raw.startsWith("diff --")) {
      inHeader = true;
      path = null;
    } else if (inHeader && raw.startsWith("+++ ")) {
      path = raw === "+++ /dev/null" ? null : raw.slice(4).replace(/^"?b\//, "").replace(/"$/, "");
    } else if (raw.startsWith("@@")) {
      inHeader = false;
      lineNo = Number(/\+(\d+)/.exec(raw)?.[1] ?? 0);
      track = contextTracker();
    } else if (raw.startsWith("+") && path) {
      scanLine(path, lineNo, raw.slice(1), out, track(raw.slice(1)), commit ? { commit } : {});
      lineNo++;
    } else if (raw.startsWith(" ") && path) {
      track(raw.slice(1));
      lineNo++;
    }
  };
}

function scanStaged() {
  const out = [];
  const feed = diffScanner(out);
  const diff = git(["diff", "--cached", "-U3", "--no-color", "--no-ext-diff", "--diff-filter=ACMR"]);
  for (const line of diff.split("\n")) feed(line);
  return out;
}

async function scanHistory() {
  const out = [];
  const feed = diffScanner(out);
  const child = spawn(
    "git",
    // --cc also shows what a merge commit itself added (conflict resolutions).
    ["log", "--all", "-p", "--cc", "-U3", "--no-color", "--no-ext-diff", "--no-renames", "--format=commit:%H"],
    { stdio: ["ignore", "pipe", "inherit"] },
  );
  for await (const line of createInterface({ input: child.stdout, crlfDelay: Infinity })) feed(line);
  const code = await new Promise((resolve) => child.on("close", resolve));
  if (code !== 0) process.exit(2);
  return out;
}

// ---------------------------------------------------------------------------

const args = process.argv.slice(2);
let findings;
if (args[0] === "--staged") findings = scanStaged();
else if (args[0] === "--history") findings = await scanHistory();
else if (args[0]?.startsWith("-")) {
  process.stderr.write("usage: node scripts/secret-scan.mjs [--staged | --history | FILE...]\n");
  process.exit(2);
} else if (args.length) {
  // Relative to where the script was run, reported relative to the repo root
  // (where the allowlist paths point).
  findings = scanFiles(
    args.map((a) => relative(ROOT, resolve(CALLER_CWD, a)) || "."),
    { named: true },
  );
} else findings = scanFiles(git(["ls-files", "-z"]).split("\0").filter(Boolean));

for (const f of findings) {
  if (f.commit) {
    const fp = createHash("sha256").update(f.value).digest("hex").slice(0, 8);
    console.log(`${f.commit}  ${f.path}:${f.lineNo}  ${f.rule}  ${f.value.slice(0, 3)}… len=${f.value.length} fp=${fp}`);
  } else {
    console.log(`${f.path}:${f.lineNo}  ${f.rule}`);
  }
}
if (findings.length) {
  console.error(
    `secret-scan: ${findings.length} possible secret(s). Remove each one (and rotate it if it was ever real). ` +
      "A known test literal gets a narrow [[allowlists]] entry in .gitleaks.toml.",
  );
  process.exit(1);
}
