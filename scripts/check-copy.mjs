#!/usr/bin/env node
/**
 * MoolaHub copy linter — keeps UI copy human/fintech and catches the
 * "AI-default" tells before they merge. Pure Node, no dependencies.
 *
 * Rules (see docs/brand/BRAND_VOICE.md):
 *  1. em-dash      — no em-dash (—) in UI copy. Use periods/commas.
 *  2. notif-emoji  — no emoji in notify()/toast title/body/description (banking tone).
 *  3. loading-dots — "Loading ..." must use a real ellipsis (…), not "...".
 *  4. title-label  — <Label> uses sentence case, not Title Case.
 *  5. claims       — no "grow your money" / "grow together" growth claims.
 *  6. crypto-term / banking-term — locale JSON (all 7 languages) never shows
 *     crypto plumbing (USDC, wallet, gas, blockchain, 0x…, Privy, Monad…) or
 *     banking words (interest, savings account, deposit insurance, bank,
 *     insured, deposit, APY, yield) outside the `technical.*` and `legal.*`
 *     keys of each namespace (spec §1 "Copy guard"). English terms are checked
 *     in every locale; each language also has its own word list.
 *  7. api-copy     — user-facing strings in TS (notification title/body,
 *     activity descriptions, AppError/`error:` messages) carry no crypto
 *     plumbing, and no TS copy uses "interest", "savings account" or
 *     "deposit insurance" wording.
 *
 * Scope: only shipped UI copy. Test files (*.e2e.ts, *.test.ts) are skipped, and
 * the em-dash rule skips long-form lesson article bodies (lessons-data.ts), where
 * editorial em-dashes are fine — only its titles/summaries were curated by hand.
 *
 * Escape hatch: put `copy-lint-ok` in a comment on the same line for a
 * deliberate exception.
 *
 * Usage: node scripts/check-copy.mjs   (exits 1 if any violation)
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, basename, dirname } from "node:path";

const ROOTS = ["artifacts/moolahub-app/src", "artifacts/api-server/src"];
const EXT = new Set([".ts", ".tsx"]);
const SKIP = /node_modules|\/dist\/|\.d\.ts$|\.e2e\.ts$|\.test\.ts$|check-copy\.mjs$/;
const EMOJI = /\p{Extended_Pictographic}/u;

function walk(dir, out = []) {
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return out;
  }
  for (const name of entries) {
    const p = join(dir, name);
    if (SKIP.test(p)) continue;
    const s = statSync(p);
    if (s.isDirectory()) walk(p, out);
    else if (EXT.has(p.slice(p.lastIndexOf(".")))) out.push(p);
  }
  return out;
}

/** Remove block comments and line comments (keeping `://` in URLs intact). */
function stripComments(src) {
  const noBlock = src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
  return noBlock
    .split("\n")
    .map((l) => l.replace(/(^|[^:])\/\/.*$/, "$1"))
    .join("\n");
}

const violations = [];

// 7. TS user-facing strings. Only string literals are inspected, and only on
// lines that hand copy to users: notification/email fields, activity
// descriptions and error messages (an AppError's message may sit on the next
// line). Code identifiers like `onchainStatus` are never string contents.
const USER_STRING_LINE = /\b(title|body|description|subject|heading|text|error)\s*:|AppError\(/;
const TS_CRYPTO = /\bUSDC\b|\bMonad\b|\bPrivy\b|\b(on|off)-?chain\b|\bblockchain\b|\bwallets?\b|\b0x[0-9a-f]|\bgas\b|\bnon-custodial\b|\bfaucet\b/i;
const TS_BANKING = /\binterest\b|\bsavings? accounts?\b|deposit insurance/i;
const STRING_LIT = /"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|`((?:[^`\\]|\\.)*)`/g;

function literals(line) {
  const out = [];
  for (const m of line.matchAll(STRING_LIT)) out.push(m[1] ?? m[2] ?? m[3] ?? "");
  return out;
}

function checkTsLine(file, lineNo, line, nextLine) {
  if (/copy-lint-ok/.test(line)) return;
  const own = literals(line);
  if (own.some((s) => TS_BANKING.test(s))) flag(file, lineNo, "api-copy", line);
  // Lessons about the plumbing are the app's opt-in "Under the hood" track
  // (shown only with Technical details on), so they may name it.
  if (/lessons-data\.ts$/.test(file)) return;
  if (!USER_STRING_LINE.test(line)) return;
  // `throw new AppError(` with the message on the following line.
  const texts = own.length === 0 && /AppError\(\s*$/.test(line) && !/copy-lint-ok/.test(nextLine) ? literals(nextLine) : own;
  if (texts.some((s) => TS_CRYPTO.test(s))) flag(file, lineNo, "api-copy", own.length ? line : nextLine);
}
const flag = (file, lineNo, rule, text) =>
  violations.push({ file, lineNo, rule, text: text.trim().slice(0, 100) });

for (const root of ROOTS) {
  for (const file of walk(root)) {
    const raw = readFileSync(file, "utf8");
    const isLessons = /lessons-data\.ts$/.test(file);
    const lines = stripComments(raw).split("\n");
    lines.forEach((line, i) => {
      const lineNo = i + 1;
      if (/copy-lint-ok/.test(line)) return;

      // 1. em-dash in UI copy (skip lesson article bodies + lone "—" placeholders)
      if (!isLessons && line.includes("—")) {
        const lone = /(["'>(]\s*)—(\s*["'<),])/.test(line) || line.trim() === "—";
        if (!lone) flag(file, lineNo, "em-dash", line);
      }
      // 2. emoji in notification/toast copy
      if (/\b(title|body|description)\s*:/.test(line) && EMOJI.test(line)) {
        flag(file, lineNo, "notif-emoji", line);
      }
      // 3. "Loading ..." three ASCII dots
      if (/Loading[^"'`<]*\.\.\./.test(line)) flag(file, lineNo, "loading-dots", line);
      // 4. Title-Case <Label>
      if (/<Label>\s*[A-Z][a-z]+ [A-Z][a-z]+/.test(line)) flag(file, lineNo, "title-label", line);
      // 5. growth claims
      if (/grow your money|grow together/i.test(line)) flag(file, lineNo, "claims", line);
      // 7. crypto plumbing / banking wording in user-facing TS strings
      checkTsLine(file, lineNo, line, lines[i + 1] ?? "");
    });
  }
}

// ---------------------------------------------------------------------------
// 6. Locale copy guard: crypto and banking terms outside technical.* / legal.*
// ---------------------------------------------------------------------------

const LOCALES_DIR = "artifacts/moolahub-app/src/i18n/locales";
// Namespaces' top-level keys that may name the plumbing or carry disclosures.
const ALLOWED_ROOTS = new Set(["technical", "legal"]);

/** Checked in every locale (loanwords like USDC/Privy/0x are never translated). */
const CRYPTO_TERMS = [
  ["USDC/USDT", /\bUSD[CT]\b/i],
  ["stablecoin", /stablecoin/i],
  ["crypto", /\bcrypto(currency|currencies)?\b/i],
  ["Monad", /\bMonad\b/i],
  ["MON", /\bMON\b/],
  ["Base network", /\bon Base\b|\bBase (mainnet|Sepolia|network)\b|basescan/],
  ["wallet", /\bwallets?\b/i],
  ["web3", /\bweb3\b/i],
  ["0x address", /\b0x/i],
  ["gas", /\bgas\b/i],
  ["blockchain", /\bblock ?chain/i],
  ["chain", /\b(on|off)?-?chain\b/i],
  ["Privy", /\bPrivy\b/i],
  ["hash", /\bhash(es)?\b/i],
  ["token", /\btokens?\b/i],
  ["escrow", /\bescrow\b/i],
  ["vault", /\bvaults?\b/i],
  ["smart contract", /smart contract/i],
  ["explorer", /\bexplorer\b/i],
  ["faucet", /\bfaucet\b/i],
  ["testnet", /\btestnet\b/i],
  ["keys", /seed phrase|private key|recovery phrase/i],
  ["custody", /custod(y|ial|ian)/i],
  ["mint", /\bmint(s|ed|ing)?\b/i],
];
const BANKING_TERMS = [
  ["interest", /\binterest\b/i],
  ["savings account", /\bsavings? accounts?\b/i],
  ["deposit insurance", /deposit insurance/i],
  ["insured", /\b(un)?insured\b|\binsurance\b|\bFDIC\b/i],
  ["bank", /\bbank(s|ing)?\b/i],
  ["deposit", /\bdeposit(s|ed|ing)?\b/i],
  ["APY", /\bAP[YR]\b/],
  ["yield", /\byields?\b/i],
];
/** Each language's own words for the same concepts. */
const LOCALE_TERMS = {
  fr: [
    ["portefeuille", /portefeuille/i],
    ["dépôt", /\bdépôts?\b/i],
    ["intérêt", /\bintérêts?\b/i],
    ["banque", /\bbanques?\b|\bbancaires?\b/i],
    ["compte d'épargne", /compte d['’]épargne/i],
    ["assurance", /\bassuré(e|es|s)?\b|\bassurance\b/i],
    ["rendement", /\brendements?\b/i],
    ["jeton", /\bjetons?\b/i],
    ["chaîne", /sur la chaîne|en chaîne/i],
  ],
  ar: [
    ["محفظة", /محفظ|محافظ/],
    ["إيداع", /إيداع|الإيداع/],
    ["بنك", /بنك|مصرف/],
    ["بلوك تشين", /بلوك ?تشين/],
    ["فائدة", /الفائدة|فوائد/],
    ["تأمين", /تأمين|مؤمَّن|مؤمّن/],
    ["حساب توفير", /حساب (توفير|ادخار)/],
    ["عائد", /عائد/],
  ],
  sw: [
    ["pochi", /\bpochi\b/i],
    ["amana", /\bamana\b/i],
    ["riba", /\briba\b/i],
    ["benki", /\bbenki\b/i],
    ["mnyororo", /mnyororo/i],
    ["akaunti ya akiba", /akaunti ya akiba/i],
    ["bima", /\bbima\b/i],
  ],
  // "riba" is left out: in Hausa it is the everyday word for profit/gain.
  ha: [
    ["walat", /\bwalat\b/i],
    ["banki", /\bbanki\b/i],
    ["sarkar", /\bsarkar\b/i],
    ["inshora", /\binshora/i],
  ],
  zh: [
    ["钱包", /钱包/],
    ["存款", /存款/],
    ["利息", /利息/],
    ["银行", /银行/],
    ["区块链", /区块链/],
    ["链上", /链上/],
    ["储蓄账户", /储蓄账户/],
    ["保险", /保险/],
    ["年化", /年化/],
    ["代币", /代币/],
    ["托管", /托管/],
  ],
  pcm: [],
  en: [],
};

function* flatten(obj, prefix = "") {
  for (const [k, v] of Object.entries(obj)) {
    const path = prefix ? `${prefix}.${k}` : k;
    if (v && typeof v === "object") yield* flatten(v, path);
    else if (typeof v === "string") yield [path, v];
  }
}

let localeFiles = 0;
const localeNames = (() => {
  try {
    return readdirSync(LOCALES_DIR).filter((d) => statSync(join(LOCALES_DIR, d)).isDirectory());
  } catch {
    return [];
  }
})();
for (const lng of localeNames) {
  const extra = LOCALE_TERMS[lng];
  if (!extra) {
    violations.push({ file: join(LOCALES_DIR, lng), lineNo: 0, rule: "crypto-term", text: `no word list for locale "${lng}"` });
    continue;
  }
  for (const name of readdirSync(join(LOCALES_DIR, lng)).filter((f) => f.endsWith(".json"))) {
    const file = join(LOCALES_DIR, lng, name);
    const raw = readFileSync(file, "utf8");
    localeFiles++;
    let json;
    try {
      json = JSON.parse(raw);
    } catch (e) {
      flag(file, 0, "crypto-term", `invalid JSON: ${e.message}`);
      continue;
    }
    for (const [path, value] of flatten(json)) {
      if (ALLOWED_ROOTS.has(path.split(".")[0])) continue;
      const hits = [
        ...CRYPTO_TERMS.filter(([, re]) => re.test(value)).map(([t]) => ["crypto-term", t]),
        ...BANKING_TERMS.filter(([, re]) => re.test(value)).map(([t]) => ["banking-term", t]),
        ...extra.filter(([, re]) => re.test(value)).map(([t]) => ["crypto-term", t]),
      ];
      if (hits.length === 0) continue;
      // Report the line of the key in the file so the editor jump works.
      const key = path.split(".").pop();
      const lineNo = raw.split("\n").findIndex((l) => l.includes(`"${key}"`)) + 1;
      for (const [rule, term] of hits) flag(file, lineNo, rule, `${basename(dirname(file))}/${name} ${path} [${term}]: ${value}`);
    }
  }
}
if (localeNames.length > 0 && localeFiles === 0) {
  violations.push({ file: LOCALES_DIR, lineNo: 0, rule: "crypto-term", text: "no locale files found" });
}

if (violations.length === 0) {
  console.log("✓ copy lint passed — no AI-default copy tells or crypto/banking terms found.");
  process.exit(0);
}

const HELP = {
  "em-dash": "Use a period or comma instead of an em-dash (or add `copy-lint-ok`).",
  "notif-emoji": "Remove the emoji from this notification/toast (banking tone).",
  "loading-dots": 'Use the ellipsis character "…" instead of "...".',
  "title-label": 'Use sentence case for form labels (e.g. "Goal name").',
  claims: "Avoid growth claims; talk about saving and reaching goals.",
  "crypto-term":
    "Use the glossary (Balance, Add money, Move to goal, Pay in, Cash out, Processing…). Plumbing words belong under technical.* only.",
  "banking-term":
    "Never say interest, savings account, deposit, bank or insured in product copy; required disclosures live under legal.* only.",
  "api-copy": "Users see dollars and plain outcomes: no USDC/wallet/on-chain/0x in messages, and no interest or savings-account wording.",
};
console.error(`✗ copy lint found ${violations.length} issue(s):\n`);
for (const v of violations) {
  console.error(`  [${v.rule}] ${v.file}:${v.lineNo}`);
  console.error(`      ${v.text}`);
  console.error(`      → ${HELP[v.rule]}\n`);
}
process.exit(1);
