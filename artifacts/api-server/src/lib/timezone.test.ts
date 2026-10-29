/**
 * Unit tests for time zone validation (no DB).
 * Run: pnpm --filter @workspace/api-server exec tsx --test src/lib/timezone.test.ts
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { normalizeTimeZone } from "./timezone";

test("IANA zone names are returned exactly as given (not canonicalised)", () => {
  for (const tz of [
    "Africa/Accra",
    "Europe/London",
    "America/Argentina/Buenos_Aires",
    "America/Indiana/Indianapolis",
    "Etc/GMT+5",
    "UTC",
    "GMT",
  ]) {
    assert.equal(normalizeTimeZone(tz), tz);
  }
});

test("surrounding spaces are trimmed", () => {
  assert.equal(normalizeTimeZone(" Africa/Lagos "), "Africa/Lagos");
});

test("offsets, unknown zones, paths, empty and over-long names are refused", () => {
  for (const bad of ["Mars/Base", "+05:00", "GMT+0530", "../etc/passwd", "", `Africa/${"A".repeat(58)}`]) {
    assert.equal(normalizeTimeZone(bad), null, `${JSON.stringify(bad)} is refused`);
  }
  assert.equal(`Africa/${"A".repeat(58)}`.length, 65);
});

test("non-strings are refused", () => {
  for (const bad of [5, null, undefined]) assert.equal(normalizeTimeZone(bad), null);
});
