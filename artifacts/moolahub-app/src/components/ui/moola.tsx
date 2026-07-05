import * as React from "react";
import { ArrowUpRight } from "lucide-react";
import { cn } from "@/lib/utils";

/* ---------------------------------------------------------------- GlassPanel */

/** A frosted-glass surface. Set `hover` for the interactive lift + glow. */
export function GlassPanel({
  className,
  children,
  hover = false,
  ...props
}: React.HTMLAttributes<HTMLDivElement> & { hover?: boolean }) {
  return (
    <div
      className={cn(
        "mh-glass rounded-[var(--mh-radius-lg)]",
        hover && "mh-glass-hover",
        className,
      )}
      {...props}
    >
      {children}
    </div>
  );
}

/** A padded glass card — the default content container of the new system. */
export function GlassCard({
  className,
  children,
  hover = false,
  ...props
}: React.HTMLAttributes<HTMLDivElement> & { hover?: boolean }) {
  return (
    <GlassPanel hover={hover} className={cn("p-5 md:p-6", className)} {...props}>
      {children}
    </GlassPanel>
  );
}

/* ---------------------------------------------------------------- MetricCard */

export function MetricCard({
  label,
  value,
  helper,
  icon,
  trend,
  className,
}: {
  label: React.ReactNode;
  value: React.ReactNode;
  helper?: React.ReactNode;
  icon?: React.ReactNode;
  trend?: React.ReactNode;
  className?: string;
}) {
  return (
    <GlassCard hover className={cn("min-h-[112px]", className)}>
      <div className="flex items-start justify-between gap-4">
        <div className="min-w-0">
          <p className="text-sm text-[var(--mh-muted)]">{label}</p>
          <div className="mt-2 font-display text-2xl font-semibold tracking-[-0.035em] text-[var(--mh-text-strong)]">
            {value}
          </div>
          {helper ? (
            <div className="mt-2 text-sm text-[var(--mh-muted)]">{helper}</div>
          ) : null}
        </div>
        {icon ? (
          <div className="grid size-11 shrink-0 place-items-center rounded-2xl border border-[rgba(45,212,166,0.18)] bg-[rgba(45,212,166,0.09)] text-[var(--mh-mint)]">
            {icon}
          </div>
        ) : null}
      </div>
      {trend ? (
        <div className="mt-3 inline-flex items-center gap-1 text-sm font-medium text-[var(--mh-mint)]">
          {trend}
        </div>
      ) : null}
    </GlassCard>
  );
}

/* -------------------------------------------------------------- Action buttons */

/** Primary glass action. Renders a `<button>`; pass `arrow` for a trailing icon.
 *  For navigation, prefer the shared `<Button href>`; this is for form/submit. */
export function PrimaryAction({
  children,
  className,
  arrow = false,
  type = "button",
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement> & { arrow?: boolean }) {
  return (
    <button
      type={type}
      className={cn(
        "mh-btn-primary focus-ring inline-flex h-12 items-center justify-center gap-2 rounded-2xl px-5 text-sm font-semibold",
        className,
      )}
      {...props}
    >
      {children}
      {arrow ? <ArrowUpRight className="size-4 rtl:-scale-x-100" /> : null}
    </button>
  );
}

export function SecondaryAction({
  children,
  className,
  type = "button",
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement>) {
  return (
    <button
      type={type}
      className={cn(
        "mh-btn-secondary focus-ring inline-flex h-12 items-center justify-center gap-2 rounded-2xl px-5 text-sm font-semibold",
        className,
      )}
      {...props}
    >
      {children}
    </button>
  );
}

/* ----------------------------------------------------------------- StatusPill */

export function StatusPill({
  children,
  tone = "jade",
  className,
}: {
  children: React.ReactNode;
  tone?: "jade" | "amber" | "danger" | "neutral";
  className?: string;
}) {
  const toneClass = {
    jade: "border-[rgba(45,212,166,0.24)] bg-[rgba(45,212,166,0.1)] text-[var(--mh-mint)]",
    amber: "border-[rgba(242,184,75,0.28)] bg-[rgba(242,184,75,0.1)] text-[var(--mh-warning)]",
    danger: "border-[rgba(255,107,107,0.28)] bg-[rgba(255,107,107,0.1)] text-[var(--mh-danger)]",
    neutral: "border-[rgba(230,243,239,0.14)] bg-[rgba(230,243,239,0.06)] text-[var(--mh-muted)]",
  }[tone];

  return (
    <span
      className={cn(
        "inline-flex items-center gap-1 whitespace-nowrap rounded-full border px-2.5 py-1 text-xs font-semibold",
        toneClass,
        className,
      )}
    >
      {children}
    </span>
  );
}

/* --------------------------------------------------------------- ProgressLine */

export function ProgressLine({
  value,
  className,
}: {
  value: number;
  className?: string;
}) {
  const safeValue = Math.max(0, Math.min(100, Number.isFinite(value) ? value : 0));
  return (
    <div className={cn("mh-progress-track h-2", className)}>
      <div className="mh-progress-bar" style={{ width: `${safeValue}%` }} />
    </div>
  );
}

/* -------------------------------------------------------------- GlowLineChart */

/** Decorative glowing line chart for hero cards. Purely ornamental. */
export function GlowLineChart({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 420 180" className={className} fill="none" aria-hidden="true" preserveAspectRatio="none">
      <defs>
        <linearGradient id="mhChartLine" x1="0" x2="420" y1="0" y2="0">
          <stop stopColor="#0E9E6E" stopOpacity="0.15" />
          <stop offset="0.55" stopColor="#22C78B" />
          <stop offset="1" stopColor="#B8FFE7" />
        </linearGradient>
        <linearGradient id="mhChartFill" x1="0" x2="0" y1="0" y2="180">
          <stop stopColor="#2DD4A6" stopOpacity="0.26" />
          <stop offset="1" stopColor="#2DD4A6" stopOpacity="0" />
        </linearGradient>
        <filter id="mhGlow" x="-20%" y="-20%" width="140%" height="140%">
          <feGaussianBlur stdDeviation="5" result="blur" />
          <feMerge>
            <feMergeNode in="blur" />
            <feMergeNode in="SourceGraphic" />
          </feMerge>
        </filter>
      </defs>
      <path
        d="M10 142 C58 132 80 154 120 120 C152 92 184 118 220 84 C260 45 286 92 326 54 C358 22 382 44 410 8"
        stroke="url(#mhChartLine)"
        strokeWidth="4"
        strokeLinecap="round"
        filter="url(#mhGlow)"
      />
      <path
        d="M10 142 C58 132 80 154 120 120 C152 92 184 118 220 84 C260 45 286 92 326 54 C358 22 382 44 410 8 L410 180 L10 180 Z"
        fill="url(#mhChartFill)"
      />
      <circle cx="410" cy="8" r="4" fill="#DFFFF3" />
    </svg>
  );
}
