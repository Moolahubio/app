/**
 * Money is ALWAYS handled as integer cents internally. `cents` is the value in
 * 1/100 of the major unit (USDC).
 */
export function formatMoney(
  cents: number,
  opts: { currency?: string; compact?: boolean; sign?: boolean } = {},
) {
  const { currency = "USDC", compact = false, sign = false } = opts;
  const value = cents / 100;
  const formatted = new Intl.NumberFormat("en-US", {
    minimumFractionDigits: compact ? 0 : 2,
    maximumFractionDigits: compact ? 1 : 2,
    notation: compact ? "compact" : "standard",
  }).format(Math.abs(value));
  const prefix = sign && value > 0 ? "+" : value < 0 ? "−" : "";
  return `${prefix}${formatted} ${currency}`;
}

/** Truncate a blockchain address for display: 0xAB…CDEF */
export function truncateAddress(addr: string, lead = 4, tail = 4) {
  if (!addr) return "";
  if (addr.length <= lead + tail + 1) return addr;
  return `${addr.slice(0, lead)}…${addr.slice(-tail)}`;
}
