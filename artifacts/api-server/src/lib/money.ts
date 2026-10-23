/**
 * Money is ALWAYS handled as integer cents internally. `cents` is the value in
 * 1/100 of a US dollar. User-facing text shows dollars ("$12.50"); the asset a
 * balance is held in (USDC) is never named in notifications or activity copy.
 */
export function formatMoney(
  cents: number,
  opts: { compact?: boolean; sign?: boolean } = {},
) {
  const { compact = false, sign = false } = opts;
  const value = cents / 100;
  const formatted = new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: compact ? 0 : 2,
    maximumFractionDigits: compact ? 1 : 2,
    notation: compact ? "compact" : "standard",
  }).format(Math.abs(value));
  const prefix = sign && value > 0 ? "+" : value < 0 ? "−" : "";
  return `${prefix}${formatted}`;
}

/** Truncate an account address for logs and technical views: 0xAB…CDEF */
export function truncateAddress(addr: string, lead = 4, tail = 4) {
  if (!addr) return "";
  if (addr.length <= lead + tail + 1) return addr;
  return `${addr.slice(0, lead)}…${addr.slice(-tail)}`;
}

/**
 * Parse a basis-points setting (e.g. GOAL_FEE_BPS) from the environment.
 * Unset or empty → `fallback`. An explicit integer 0..10000 is used as-is, so
 * "0" means a 0% fee; `Number(x) || fallback` would silently turn it into the
 * default. Anything else (negative, fractional, junk) is a misconfiguration:
 * it falls back to the default and is reported through `onInvalid`.
 */
export function parseBps(
  raw: string | undefined,
  fallback: number,
  onInvalid?: (raw: string) => void,
): number {
  if (raw === undefined || raw.trim() === "") return fallback;
  const s = raw.trim();
  const n = /^\d{1,5}$/.test(s) ? Number(s) : NaN;
  if (Number.isInteger(n) && n >= 0 && n <= 10_000) return n;
  onInvalid?.(raw);
  return fallback;
}
