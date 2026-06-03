import * as React from "react";
import { cn, pct } from "@/lib/utils";

export { Button } from "./ui/button";
export type { ButtonProps, ButtonSize, ButtonVariant } from "./ui/button";

/* ------------------------------------------------------------------- Card */

export function Card({
  className,
  children,
  ...props
}: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      className={cn(
        "rounded-2xl border border-ink-900/[0.08] bg-white",
        className,
      )}
      {...props}
    >
      {children}
    </div>
  );
}

/* ------------------------------------------------------------------ Badge */

type BadgeTone = "jade" | "ink" | "amber" | "neutral" | "sky";

const badgeTones: Record<BadgeTone, string> = {
  jade: "bg-jade-50 text-jade-700 ring-jade-500/20",
  ink: "bg-ink-900 text-white ring-white/10",
  amber: "bg-amber-50 text-amber-700 ring-amber-500/20",
  neutral: "bg-ink-900/[0.05] text-ink-600 ring-ink-900/10",
  sky: "bg-sky-50 text-sky-700 ring-sky-500/20",
};

export function Badge({
  tone = "neutral",
  className,
  children,
}: {
  tone?: BadgeTone;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium ring-1 ring-inset",
        badgeTones[tone],
        className,
      )}
    >
      {children}
    </span>
  );
}

/* ----------------------------------------------------------- Progress bar */

export function ProgressBar({
  value,
  total,
  className,
  tone = "jade",
}: {
  value: number;
  total: number;
  className?: string;
  tone?: "jade" | "ink";
}) {
  const percentage = pct(value, total);
  return (
    <div className={cn("h-2 w-full overflow-hidden rounded-full bg-ink-900/[0.07]", className)}>
      <div
        className={cn(
          "h-full rounded-full transition-all duration-700",
          tone === "jade" ? "bg-jade-500" : "bg-ink-900",
        )}
        style={{ width: `${percentage}%` }}
      />
    </div>
  );
}

/* -------------------------------------------------------------- Eyebrow */

export function Eyebrow({
  children,
  className,
  tone = "jade",
}: {
  children: React.ReactNode;
  className?: string;
  tone?: "jade" | "muted" | "light";
}) {
  return (
    <p
      className={cn(
        "eyebrow",
        tone === "jade" && "text-jade-600",
        tone === "muted" && "text-ink-400",
        tone === "light" && "text-jade-300",
        className,
      )}
    >
      {children}
    </p>
  );
}

/* ------------------------------------------------------------------ Avatar */

export function Avatar({
  name,
  src,
  className,
  tone = "jade",
}: {
  name: string;
  src?: string | null;
  className?: string;
  tone?: "jade" | "ink" | "amber" | "sky";
}) {
  const initials = name
    .split(" ")
    .map((n) => n[0])
    .slice(0, 2)
    .join("")
    .toUpperCase();
  const tones: Record<string, string> = {
    jade: "bg-jade-100 text-jade-700",
    ink: "bg-ink-900 text-white",
    amber: "bg-amber-100 text-amber-700",
    sky: "bg-sky-100 text-sky-700",
  };
  if (src) {
    return (
      <img
        src={src}
        alt={name}
        className={cn(
          "inline-block rounded-full object-cover",
          className ?? "h-9 w-9",
        )}
      />
    );
  }
  return (
    <span
      className={cn(
        "inline-flex items-center justify-center rounded-full text-xs font-semibold",
        tones[tone],
        className ?? "h-9 w-9",
      )}
    >
      {initials}
    </span>
  );
}

/* --------------------------------------------------------------- IconChip */

export function IconChip({
  children,
  className,
  tone = "jade",
}: {
  children: React.ReactNode;
  className?: string;
  tone?: "jade" | "ink" | "amber" | "sky";
}) {
  const tones: Record<string, string> = {
    jade: "bg-jade-50 text-jade-600",
    ink: "bg-ink-900/[0.06] text-ink-700",
    amber: "bg-amber-50 text-amber-600",
    sky: "bg-sky-50 text-sky-600",
  };
  return (
    <span
      className={cn(
        "inline-flex h-11 w-11 items-center justify-center rounded-2xl",
        tones[tone],
        className,
      )}
    >
      {children}
    </span>
  );
}

/* -------------------------------------------------------------- Skeleton */

export function Skeleton({ className }: { className?: string }) {
  return (
    <div
      className={cn("animate-pulse rounded-2xl bg-ink-900/[0.06]", className)}
      aria-hidden
    />
  );
}

/* ------------------------------------------------------------- EmptyState */

export function EmptyState({
  title,
  description,
  action,
}: {
  title: string;
  description: string;
  action?: React.ReactNode;
}) {
  return (
    <div className="flex flex-col items-center rounded-3xl border border-dashed border-ink-900/10 bg-white px-6 py-12 text-center">
      <p className="font-display text-lg font-bold text-ink-900">{title}</p>
      <p className="mt-2 max-w-sm text-sm text-ink-500">{description}</p>
      {action ? <div className="mt-6">{action}</div> : null}
    </div>
  );
}
