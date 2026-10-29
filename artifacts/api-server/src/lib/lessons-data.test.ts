/**
 * Guard tests for the lesson text (no DB). The apps show it verbatim, so it
 * follows the copy rules: no em dash, no "!", sentence case, no claim the product
 * can't back, and no crypto words in the lessons iOS shows.
 * Run: pnpm --filter @workspace/api-server exec tsx --test src/lib/lessons-data.test.ts
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { LESSONS, type LessonDef } from "./lessons-data";

/** The categories iOS shows (the crypto and remittance lessons are web only). */
const VISIBLE = new Set(["circles", "personal-finance"]);
const visible = LESSONS.filter((l) => VISIBLE.has(l.category));

/** Every text field of a lesson: never `slug` or `category` (the key "circles" is not copy). */
function texts(l: LessonDef): string[] {
  return [l.title, l.summary, ...l.body.flatMap((b) => [b.heading, b.text]), ...l.takeaways];
}

function findings(lessons: LessonDef[], re: RegExp): string[] {
  return lessons.flatMap((l) => texts(l).filter((t) => re.test(t)).map((t) => `${l.slug}: ${t}`));
}

test("no em dash in any lesson", () => {
  assert.deepEqual(findings(LESSONS, /—/), []);
});

test("no exclamation mark in any lesson", () => {
  assert.deepEqual(findings(LESSONS, /!/), []);
});

test("visible titles and headings are in sentence case", () => {
  // Proper nouns and acronyms keep their capitals. A lesson that needs another
  // one extends this list in the same change.
  const allowed = new Set(["SMART", "USDC", "Susu", "MoolaHub", "Africa"]);
  const bad = visible.flatMap((l) =>
    [l.title, ...l.body.map((b) => b.heading)].filter((s) =>
      s
        .split(/\s+/)
        .slice(1)
        .map((w) => w.replace(/[^A-Za-z]/g, ""))
        .some((w) => /[A-Z]/.test(w) && !allowed.has(w)),
    ),
  );
  assert.deepEqual(bad, []);
});

test("no join-preview claim in any lesson", () => {
  assert.deepEqual(findings(LESSONS, /before you join|up front/i), []);
});

test("the visible lessons carry no crypto words", () => {
  assert.deepEqual(findings(visible, /\b(usdc|wallet|blockchain|on-?chain|nft|hash|explorer|gas|privy|monad|crypto)\b/i), []);
  assert.deepEqual(findings(visible, /\bBase\b/), []);
});

test("the visible lessons avoid the words the brand keeps out", () => {
  for (const re of [/\bcircle/i, /\bcontribut/i, /insur/i, /separate/i, /(entire|whole) pot/i, /protect/i]) {
    assert.deepEqual(findings(visible, re), [], `${re} matches`);
  }
});

test("every lesson is complete", () => {
  for (const l of LESSONS) {
    assert.ok(l.body.some((b) => b.heading.trim() && b.text.trim()), `${l.slug} has a section`);
    assert.ok(l.takeaways.length > 0, `${l.slug} has a takeaway`);
    assert.ok(l.minutes > 0, `${l.slug} has minutes`);
    assert.ok(["beginner", "intermediate", "advanced"].includes(l.level), `${l.slug} has a level`);
  }
});

test("slugs and categories keep their order", () => {
  assert.deepEqual(
    LESSONS.map((l) => l.slug),
    [
      "what-is-a-susu",
      "understanding-usdc",
      "setting-savings-goals",
      "building-an-emergency-fund",
      "understanding-blockchain",
      "sending-money-internationally",
    ],
  );
  assert.deepEqual(
    LESSONS.map((l) => l.category),
    ["circles", "crypto", "personal-finance", "personal-finance", "crypto", "remittance"],
  );
});
