import { Link } from "wouter";
import { useTranslation } from "react-i18next";
import { AlertCircle, ArrowLeft, ArrowUpRight, CheckCircle2, Clock, Info, XCircle } from "lucide-react";
import { cn, formatMoney, truncateAddress } from "@/lib/utils";

/** Page heading used at the top of app screens. */
export function PageHeader({
  eyebrow,
  title,
  description,
  action,
}: {
  eyebrow?: string;
  title: string;
  description?: string;
  action?: React.ReactNode;
}) {
  return (
    <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
      <div>
        {eyebrow && <p className="eyebrow text-jade-600 dark:text-jade-400">{eyebrow}</p>}
        <h1 className="mt-1.5 font-display text-3xl font-bold tracking-tight text-foreground">
          {title}
        </h1>
        {description && <p className="mt-2 max-w-xl text-muted-foreground">{description}</p>}
      </div>
      {action}
    </div>
  );
}

/** Back link for detail screens. */
export function BackLink({ href, label }: { href: string; label: string }) {
  return (
    <Link
      href={href}
      className="inline-flex items-center gap-1.5 text-sm font-medium text-muted-foreground transition-colors hover:text-foreground"
    >
      <ArrowLeft className="h-4 w-4" />
      {label}
    </Link>
  );
}

// Fallback when the API doesn't send an explorer base (Technical details only).
const DEFAULT_EXPLORER = import.meta.env.VITE_EXPLORER_URL ?? "https://testnet.monadvision.com";

/**
 * Transaction ID pill linking to the public block explorer. Technical details
 * only: callers render it when the toggle is on, and a plain status otherwise.
 */
export function TxTag({
  hash,
  confirmed = true,
  explorerUrl,
}: {
  hash: string;
  confirmed?: boolean;
  explorerUrl?: string | null;
}) {
  const explorer = explorerUrl || DEFAULT_EXPLORER;
  const short = hash.length > 14 ? `${hash.slice(0, 8)}…${hash.slice(-6)}` : hash;
  const href = `${explorer.replace(/\/$/, "")}/tx/${hash}`;

  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      className={cn(
        "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 font-mono text-[11px] ring-1 ring-inset transition-colors hover:opacity-90 focus-ring",
        confirmed
          ? "bg-jade-50 text-jade-700 ring-jade-500/20 dark:bg-jade-500/15 dark:text-jade-300 dark:ring-jade-400/25"
          : "bg-amber-50 text-amber-700 ring-amber-500/20 dark:bg-amber-500/15 dark:text-amber-300 dark:ring-amber-400/25",
      )}
    >
      {confirmed ? <CheckCircle2 className="h-3 w-3" /> : <Clock className="h-3 w-3" />}
      {short}
      <ArrowUpRight className="h-3 w-3 opacity-60" />
    </a>
  );
}

/** Plain transfer status for everyday views: Processing… → Done, or didn't go through. */
export function TxStatus({ status }: { status: string | null | undefined }) {
  const { t } = useTranslation("transactions");
  const failed = status === "failed";
  const processing = status === "pending" || status === "queued";
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1 text-[11px] font-medium",
        failed ? "text-rose-600 dark:text-rose-400" : processing ? "text-amber-600 dark:text-amber-400" : "text-muted-foreground",
      )}
    >
      {failed ? <XCircle className="h-3 w-3" /> : processing ? <Clock className="h-3 w-3" /> : <CheckCircle2 className="h-3 w-3" />}
      {failed ? t("status.failed") : processing ? t("status.processing") : t("status.done")}
    </span>
  );
}

/**
 * The persistent disclosure under every balance (spec §1, disclosure 2):
 * "Held as USDC · Not a bank deposit · Not insured". Hiding the plumbing must
 * never hide what the product is.
 */
export function BalanceFooter({ className, tone = "default" }: { className?: string; tone?: "default" | "onDark" }) {
  const { t } = useTranslation();
  return (
    <p
      className={cn(
        "flex items-center gap-1.5 text-[11px]",
        tone === "onDark" ? "text-white/60" : "text-muted-foreground",
        className,
      )}
    >
      <Info className="h-3 w-3 shrink-0" aria-hidden />
      {t("legal.balanceFooter")}
    </p>
  );
}

/** Inline error with a retry button, for screens whose data failed to load. */
export function LoadError({ onRetry, className }: { onRetry?: () => void; className?: string }) {
  const { t } = useTranslation();
  return (
    <div role="alert" className={cn("flex flex-col items-center gap-3 p-8 text-center", className)}>
      <AlertCircle className="h-6 w-6 text-rose-500" aria-hidden />
      <p className="max-w-sm text-sm text-muted-foreground">{t("states.loadError")}</p>
      {onRetry && (
        <button
          type="button"
          onClick={onRetry}
          className="rounded-xl border border-border bg-card px-4 py-2 text-sm font-semibold text-foreground transition-colors hover:bg-accent focus-ring"
        >
          {t("actions.retry")}
        </button>
      )}
    </div>
  );
}

/** A money amount rendered LTR-isolated so the sign and digits never reorder
 *  inside a right-to-left layout. Use anywhere a balance/amount is shown. */
export function Money({
  cents,
  compact,
  sign,
  className,
}: {
  cents: number;
  compact?: boolean;
  sign?: boolean;
  className?: string;
}) {
  return (
    <span dir="ltr" className={className}>
      {formatMoney(cents, { compact, sign })}
    </span>
  );
}

/** An account address, truncated (0xAB…CDEF) and LTR-isolated for RTL safety. Technical details only. */
export function Addr({
  address,
  lead,
  tail,
  className,
}: {
  address: string;
  lead?: number;
  tail?: number;
  className?: string;
}) {
  return (
    <span dir="ltr" className={cn("font-mono", className)}>
      {truncateAddress(address, lead, tail)}
    </span>
  );
}
