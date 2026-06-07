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
import { join } from "node:path";

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
    });
  }
}

if (violations.length === 0) {
  console.log("✓ copy lint passed — no AI-default copy tells found.");
  process.exit(0);
}

const HELP = {
  "em-dash": "Use a period or comma instead of an em-dash (or add `copy-lint-ok`).",
  "notif-emoji": "Remove the emoji from this notification/toast (banking tone).",
  "loading-dots": 'Use the ellipsis character "…" instead of "...".',
  "title-label": 'Use sentence case for form labels (e.g. "Goal name").',
  claims: "Avoid growth claims; talk about saving and reaching goals.",
};
console.error(`✗ copy lint found ${violations.length} issue(s):\n`);
for (const v of violations) {
  console.error(`  [${v.rule}] ${v.file}:${v.lineNo}`);
  console.error(`      ${v.text}`);
  console.error(`      → ${HELP[v.rule]}\n`);
}
process.exit(1);
