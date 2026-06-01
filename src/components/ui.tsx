import * as React from "react";
import Link from "next/link";
import { cn, pct } from "@/lib/utils";

/* ----------------------------------------------------------------- Button */

type ButtonVariant = "primary" | "secondary" | "ghost" | "dark";
type ButtonSize = "sm" | "md" | "lg";

const buttonBase =
  "inline-flex items-center justify-center gap-2 rounded-full font-semibold transition-all focus-ring disabled:opacity-50 disabled:pointer-events-none whitespace-nowrap";

const buttonVariants: Record<ButtonVariant, string> = {
  primary:
    "bg-jade-500 text-white shadow-[0_8px_24px_-10px_rgba(14,158,110,0.7)] hover:bg-jade-600 active:bg-jade-700",
  secondary:
    "bg-white text-ink-900 border border-ink-900/10 hover:border-ink-900/20 hover:bg-mist shadow-sm",
  ghost: "text-ink-700 hover:bg-ink-900/5",
  dark: "bg-ink-900 text-white hover:bg-ink-800",
};

const buttonSizes: Record<ButtonSize, string> = {
  sm: "h-9 px-4 text-sm",
  md: "h-11 px-5 text-sm",
  lg: "h-13 px-7 text-base h-[52px]",
};

type ButtonProps = {
  variant?: ButtonVariant;
  size?: ButtonSize;
} & (
  | ({ href: string } & React.ComponentProps<typeof Link>)
  | ({ href?: undefined } & React.ButtonHTMLAttributes<HTMLButtonElement>)
);

export function Button({
  variant = "primary",
  size = "md",
  className,
  ...props
}: ButtonProps) {
  const classes = cn(buttonBase, buttonVariants[variant], buttonSizes[size], className);
  if (props.href !== undefined) {
    const { href, ...rest } = props as { href: string } & React.ComponentProps<typeof Link>;
    return <Link href={href} className={classes} {...rest} />;
  }
  return <button className={classes} {...(props as React.ButtonHTMLAttributes<HTMLButtonElement>)} />;
}

/* ------------------------------------------------------------------- Card */

export function Card({
  className,
  children,
  ...props
}: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      className={cn(
        "rounded-3xl border border-ink-900/[0.07] bg-white shadow-card",
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
  className,
  tone = "jade",
}: {
  name: string;
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
