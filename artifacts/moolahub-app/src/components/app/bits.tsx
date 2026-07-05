import { Link } from "wouter";
import { ArrowLeft, ArrowUpRight, CheckCircle2, Clock } from "lucide-react";
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
        {eyebrow && <p className="mh-kicker mb-2">{eyebrow}</p>}
        <h1 className="mh-page-title font-display text-3xl font-bold md:text-4xl">
          {title}
        </h1>
        {description && <p className="mt-2 max-w-xl text-muted-foreground">{description}</p>}
      </div>
      {action ? <div className="flex shrink-0 items-center gap-3">{action}</div> : null}
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

/** On-chain transaction reference — links to the Monad block explorer. */
export function TxTag({
  hash,
  confirmed = true,
}: {
  hash: string;
  confirmed?: boolean;
}) {
  const explorer = "https://testnet.monadvision.com";
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

/** A money amount rendered LTR-isolated so the sign and digits never reorder
 *  inside a right-to-left layout. Use anywhere a balance/amount is shown. */
export function Money({
  cents,
  currency,
  compact,
  sign,
  className,
}: {
  cents: number;
  currency?: string;
  compact?: boolean;
  sign?: boolean;
  className?: string;
}) {
  return (
    <span dir="ltr" className={className}>
      {formatMoney(cents, { currency, compact, sign })}
    </span>
  );
}

/** A blockchain address, truncated (0xAB…CDEF) and LTR-isolated for RTL safety. */
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
