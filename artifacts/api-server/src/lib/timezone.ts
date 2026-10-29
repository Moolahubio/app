/**
 * Time zone validation for `PATCH /profile`. No imports, so it is unit-tested
 * without a database.
 */
const IANA_SHAPE = /^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+){0,2}$/;

/** A usable IANA zone name, trimmed, or null. Offsets ("+05:00") and unknown zones are refused.
 *  The name is stored as given (not canonicalised), so a client can compare it with its own. */
export function normalizeTimeZone(input: unknown): string | null {
  if (typeof input !== "string") return null;
  const tz = input.trim();
  if (tz.length < 1 || tz.length > 64 || !IANA_SHAPE.test(tz)) return null;
  try { new Intl.DateTimeFormat("en-US", { timeZone: tz }).format(0); } catch { return null; }
  return tz;
}
