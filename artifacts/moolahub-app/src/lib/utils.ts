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
 * Format an integer cents amount as US dollars ("$12.50"), localized to the
 * active UI language. Balances are dollars to the user: the asset they're held
 * in only appears under Technical details. Digits are kept Latin
 * (`numberingSystem: "latn"`) so balances stay legible across every locale,
 * including Arabic. Money is ALWAYS handled as integers internally; `cents` is
 * 1/100 of a dollar.
 */
export function formatMoney(
  cents: number,
  opts: { compact?: boolean; sign?: boolean } = {},
) {
  const { compact = false, sign = false } = opts;
  const value = cents / 100;
  const formatted = new Intl.NumberFormat(activeLocale(), {
    style: "currency",
    currency: "USD",
    currencyDisplay: "narrowSymbol",
    minimumFractionDigits: compact ? 0 : 2,
    maximumFractionDigits: compact ? 1 : 2,
    notation: compact ? "compact" : "standard",
    numberingSystem: "latn",
  }).format(Math.abs(value));
  const prefix = sign && value > 0 ? "+" : value < 0 ? "−" : "";
  return `${prefix}${formatted}`;
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

/** Truncate an account address for display (0xAB…CDEF). Technical details only. */
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

// ---------------------------------------------------------------------------
// Errors users see
// ---------------------------------------------------------------------------

type ErrorLike = {
  name?: unknown;
  message?: unknown;
  shortMessage?: unknown;
  details?: unknown;
  code?: unknown;
  status?: unknown;
  data?: { error?: unknown } | null;
  cause?: unknown;
};

/** Every message in an error and its `cause` chain, joined for matching. */
function errorText(err: unknown, depth = 0): string {
  if (!err || typeof err !== "object" || depth > 4) return typeof err === "string" ? err : "";
  const e = err as ErrorLike;
  const own = [e.name, e.shortMessage, e.details, e.message].filter((v) => typeof v === "string").join(" ");
  return `${own} ${errorText(e.cause, depth + 1)}`;
}

/** True when the person closed or declined the confirm prompt themselves. */
export function isUserCancellation(err: unknown): boolean {
  if (!err || typeof err !== "object") return false;
  const e = err as ErrorLike;
  if (e.code === 4001) return true;
  return /UserRejectedRequestError|user rejected|user denied|user cancell?ed/i.test(errorText(err));
}

// A server message that leaks plumbing (addresses, hashes, RPC or library text)
// is never shown verbatim, even though AppError messages are meant to be safe.
const TECHNICAL_RE = /0x[0-9a-f]{6,}|\b(viem|rpc|calldata|revert(ed)?|nonce|gas|abi|HTTP \d{3})\b/i;

/**
 * Turn any thrown value into copy a person can act on. Raw `e.message` text
 * (wallet library errors, addresses, calldata, HTTP status lines) never reaches
 * the screen. Mapping:
 * - API errors: the server's own user-safe message for a 4xx, else `fallback`;
 *   5xx and network failures get "nothing moved, try again" copy.
 * - Wallet errors: cancelled, not enough money, couldn't reach the partner,
 *   still processing, or didn't go through. Anything else gets `fallback` or a
 *   generic message.
 * Returns undefined only when there is no error (and no fallback).
 */
export function toUserError(err: unknown, fallback: string): string;
export function toUserError(err: unknown, fallback?: string): string | undefined;
export function toUserError(err: unknown, fallback?: string): string | undefined {
  if (err == null) return fallback;
  const e = (typeof err === "object" ? err : {}) as ErrorLike;
  const generic = fallback ?? i18n.t("errors.generic");

  // Generated API client error (ApiError): status + parsed JSON body.
  if (e.name === "ApiError" && typeof e.status === "number") {
    const serverMsg = typeof e.data?.error === "string" ? e.data.error.trim() : "";
    if (e.status >= 500) return fallback ?? i18n.t("errors.server");
    if (serverMsg && !TECHNICAL_RE.test(serverMsg)) return serverMsg;
    if (e.status === 429) return i18n.t("errors.tooMany");
    return generic;
  }

  if (isUserCancellation(err)) return i18n.t("errors.cancelled");

  const text = errorText(err);
  if (/insufficient (funds|balance)|exceeds (the )?balance|transfer amount exceeds/i.test(text)) {
    return i18n.t("errors.notEnough");
  }
  if (/WaitForTransactionReceiptTimeout|timed out while waiting for transaction/i.test(text)) {
    return i18n.t("errors.processing");
  }
  if (/revert/i.test(text)) return i18n.t("errors.didNotGoThrough");
  if (/HttpRequestError|RpcRequestError|InternalRpcError|TimeoutError|LimitExceededRpcError|fetch failed|request timed out/i.test(text)) {
    return i18n.t("errors.partner");
  }
  if (/Failed to fetch|NetworkError|Load failed/i.test(text)) return i18n.t("errors.network");
  return generic;
}
