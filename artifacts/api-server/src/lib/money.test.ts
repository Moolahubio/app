/**
 * Unit tests for money helpers (no DB).
 * Run: pnpm --filter @workspace/api-server exec tsx --test src/lib/money.test.ts
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { formatMoney, parseBps } from "./money";

test("an explicit 0 bps fee is 0, not the default", () => {
  assert.equal(parseBps("0", 200), 0);
  assert.equal(parseBps(" 0 ", 200), 0);
});

test("unset or empty falls back to the default", () => {
  assert.equal(parseBps(undefined, 200), 200);
  assert.equal(parseBps("", 200), 200);
  assert.equal(parseBps("   ", 200), 200);
});

test("valid values are used as-is", () => {
  assert.equal(parseBps("150", 200), 150);
  assert.equal(parseBps("10000", 200), 10_000);
});

test("invalid values fall back and are reported", () => {
  const seen: string[] = [];
  for (const bad of ["-1", "2.5", "abc", "10001", "1e3", "NaN"]) {
    assert.equal(parseBps(bad, 200, (r) => seen.push(r)), 200, `"${bad}" falls back`);
  }
  assert.equal(seen.length, 6);
});

test("formats cents as US dollars without a token suffix", () => {
  assert.equal(formatMoney(1250), "$12.50");
  assert.equal(formatMoney(-29), "−$0.29");
  assert.equal(formatMoney(100_000), "$1,000.00");
  assert.equal(formatMoney(500, { sign: true }), "+$5.00");
});
