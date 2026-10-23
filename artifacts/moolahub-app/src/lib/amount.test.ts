/**
 * Run: node --test artifacts/moolahub-app/src/lib/amount.test.ts
 * (Node 22.18+ strips the TypeScript types itself; no test runner needed.)
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseAmountToCents, centsToAmountInput } from "./amount.ts";

test("parses dollars and cents without float drift", () => {
  assert.equal(parseAmountToCents("19.99"), 1999);
  assert.equal(parseAmountToCents("0.29"), 29);
  assert.equal(parseAmountToCents("1.1"), 110);
  assert.equal(parseAmountToCents("0.07"), 7);
  assert.equal(parseAmountToCents("4.35"), 435);
  assert.equal(parseAmountToCents("1000"), 100_000);
  assert.equal(parseAmountToCents("5."), 500);
  assert.equal(parseAmountToCents(".5"), 50);
  assert.equal(parseAmountToCents("0"), 0);
});

test("accepts a leading $, surrounding spaces and a decimal comma", () => {
  assert.equal(parseAmountToCents("$12.50"), 1250);
  assert.equal(parseAmountToCents(" 12.5 "), 1250);
  assert.equal(parseAmountToCents("12,5"), 1250);
});

test("rejects more than two decimals, negatives, NaN and junk", () => {
  for (const bad of ["1.999", "0.001", "-1", "-0.5", "NaN", "abc", "", " ", ".", "1e3", "1,000", "1.2.3", "Infinity", "+5"]) {
    assert.equal(parseAmountToCents(bad), null, `"${bad}" should be rejected`);
  }
});

test("rejects amounts too large to stay exact", () => {
  assert.equal(parseAmountToCents("1234567890123"), null);
  assert.equal(parseAmountToCents("999999999999.99"), 99_999_999_999_999);
});

test("formats cents back into an input string", () => {
  assert.equal(centsToAmountInput(10_000), "100");
  assert.equal(centsToAmountInput(1999), "19.99");
  assert.equal(centsToAmountInput(1007), "10.07");
  assert.equal(centsToAmountInput(5), "0.05");
  assert.equal(parseAmountToCents(centsToAmountInput(1007)), 1007);
});
