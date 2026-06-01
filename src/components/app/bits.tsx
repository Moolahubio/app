import Link from "next/link";
import { ArrowLeft, ArrowUpRight, CheckCircle2, Clock } from "lucide-react";
import { cn } from "@/lib/utils";

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
        {eyebrow && <p className="eyebrow text-jade-600">{eyebrow}</p>}
        <h1 className="mt-1.5 font-display text-3xl font-bold tracking-tight text-ink-900">
          {title}
        </h1>
        {description && <p className="mt-2 max-w-xl text-ink-500">{description}</p>}
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
      className="inline-flex items-center gap-1.5 text-sm font-medium text-ink-500 transition-colors hover:text-ink-900"
    >
      <ArrowLeft className="h-4 w-4" />
      {label}
    </Link>
  );
}

/** On-chain transaction reference chip — links to a block explorer in prod. */
export function TxTag({
  hash,
  confirmed = true,
}: {
  hash: string;
  confirmed?: boolean;
}) {
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 font-mono text-[11px] ring-1 ring-inset",
        confirmed
          ? "bg-jade-50 text-jade-700 ring-jade-500/20"
          : "bg-amber-50 text-amber-700 ring-amber-500/20",
      )}
    >
      {confirmed ? <CheckCircle2 className="h-3 w-3" /> : <Clock className="h-3 w-3" />}
      {hash}
      <ArrowUpRight className="h-3 w-3 opacity-60" />
    </span>
  );
}
