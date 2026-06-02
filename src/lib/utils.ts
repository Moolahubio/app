import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

/** Merge Tailwind classes with conditional logic. */
export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

/**
 * Format an integer minor-unit amount (e.g. USDC has 6 decimals on Base,
 * but for display we treat balances as integer cents) into a currency string.
 *
 * Money is ALWAYS handled as integers internally (see CLAUDE.md golden rule).
 * `cents` is the value in 1/100 of the major unit.
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

/** Short, human relative time for activity feeds. */
export function timeAgo(iso: string, now: Date = new Date()) {
  const diff = now.getTime() - new Date(iso).getTime();
  const mins = Math.round(diff / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.round(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  const days = Math.round(hrs / 24);
  if (days < 7) return `${days}d ago`;
  return new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric" });
}

/** Truncate a blockchain address for display: 0xAB…CDEF */
export function truncateAddress(addr: string, lead = 4, tail = 4) {
  if (addr.length <= lead + tail + 1) return addr;
  return `${addr.slice(0, lead)}…${addr.slice(-tail)}`;
}

export function pct(part: number, whole: number) {
  if (whole <= 0) return 0;
  return Math.min(100, Math.round((part / whole) * 100));
}
