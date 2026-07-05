import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";
import i18n from "@/i18n";
import { localeFor } from "@/i18n/languages";

/** Merge Tailwind classes with conditional logic. */
export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

/** BCP-47 locale for the active UI language, for Intl formatting. */
function activeLocale(): string {
  return localeFor(i18n.language);
}

/**
 * Format an integer cents amount into a currency string, localized to the
 * active UI language. Digits are kept Latin (`numberingSystem: "latn"`) so
 * balances stay legible across every locale, including Arabic.
 * Money is ALWAYS handled as integers internally; `cents` is 1/100 of the major unit.
 */
export function formatMoney(
  cents: number,
  opts: { currency?: string; compact?: boolean; sign?: boolean } = {},
) {
  const { currency = "USDC", compact = false, sign = false } = opts;
  const value = cents / 100;
  const formatted = new Intl.NumberFormat(activeLocale(), {
    minimumFractionDigits: compact ? 0 : 2,
    maximumFractionDigits: compact ? 1 : 2,
    notation: compact ? "compact" : "standard",
    numberingSystem: "latn",
  }).format(Math.abs(value));
  const prefix = sign && value > 0 ? "+" : value < 0 ? "−" : "";
  return `${prefix}${formatted} ${currency}`;
}

/** Format an ISO date, localized to the active UI language (Latin digits). */
export function formatDate(
  iso: string,
  opts: Intl.DateTimeFormatOptions = { month: "short", day: "numeric" },
) {
  return new Intl.DateTimeFormat(activeLocale(), {
    ...opts,
    numberingSystem: "latn",
  }).format(new Date(iso));
}

/** Short, human relative time for activity feeds, localized to the UI language. */
export function timeAgo(iso: string, now: Date = new Date()) {
  const diff = now.getTime() - new Date(iso).getTime();
  const mins = Math.round(diff / 60000);
  if (mins < 1) return i18n.t("time.justNow");
  if (mins < 60) return i18n.t("time.minutesAgo", { count: mins });
  const hrs = Math.round(mins / 60);
  if (hrs < 24) return i18n.t("time.hoursAgo", { count: hrs });
  const days = Math.round(hrs / 24);
  if (days < 7) return i18n.t("time.daysAgo", { count: days });
  return formatDate(iso);
}

/** Truncate a blockchain address for display: 0xAB…CDEF */
export function truncateAddress(addr: string, lead = 6, tail = 4) {
  if (!addr || addr.length <= lead + tail + 1) return addr;
  return `${addr.slice(0, lead)}…${addr.slice(-tail)}`;
}

/** Percentage of part over whole, clamped to 0–100. */
export function pct(part: number, whole: number) {
  if (whole <= 0) return 0;
  return Math.min(100, Math.round((part / whole) * 100));
}

/** Resolve a stored avatar value to a displayable URL. Stored avatars are object
 * storage paths (e.g. "/objects/<id>") served through the storage route. Only
 * internal object paths are honored; arbitrary external URLs are ignored so a
 * crafted value can't load third-party content in other users' browsers. */
export function avatarSrc(value: string | null | undefined): string | undefined {
  if (!value) return undefined;
  if (value.startsWith("/objects/")) return `/api/storage${value}`;
  return undefined;
}

/** Extract a human-readable message from an API error (ErrorType<ApiError> or unknown). */
export function apiErrorMessage(err: unknown): string | undefined {
  if (!err) return undefined;
  const e = err as { data?: { error?: string }; message?: string };
  return e.data?.error ?? e.message;
}
