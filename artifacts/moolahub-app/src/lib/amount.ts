/**
 * Money input parsing. Every amount a user types goes through here, so the
 * conversion to integer cents is done on the STRING, never with float math
 * (`parseFloat("0.29") * 100` is 28.999…, which floors to 28¢).
 *
 * Kept free of imports so it runs under `node --test` without the Vite aliases.
 */

// Whole part (up to 12 digits, so cents stay far below 2^53), then an optional
// decimal separator with at most two digits. "." and "," are both accepted as
// the separator because several supported locales type a decimal comma; there
// are no thousands separators, so "1,000" is rejected rather than misread.
const AMOUNT_RE = /^(\d{0,12})(?:[.,](\d{0,2}))?$/;

/**
 * Parse a user-typed amount into integer cents: "19.99" → 1999, "0.29" → 29,
 * "5" → 500, "$12,5" → 1250. Returns null for anything that isn't a plain
 * non-negative amount with at most two decimals (negatives, "1e3", "NaN",
 * "1.999", "", "."). Zero parses to 0; callers decide whether 0 is allowed.
 */
export function parseAmountToCents(input: string): number | null {
  const s = input.trim().replace(/^\$\s*/, "");
  const m = AMOUNT_RE.exec(s);
  if (!m) return null;
  const whole = m[1] ?? "";
  const frac = m[2] ?? "";
  if (whole === "" && frac === "") return null;
  return Number(whole || "0") * 100 + Number(frac.padEnd(2, "0"));
}

/** Integer cents back to an input string ("19.99", "100"), for presets and Max buttons. */
export function centsToAmountInput(cents: number): string {
  const c = Math.max(0, Math.trunc(cents));
  const whole = Math.floor(c / 100);
  const frac = c % 100;
  return frac === 0 ? String(whole) : `${whole}.${String(frac).padStart(2, "0")}`;
}
