import * as React from "react";
import { Link } from "wouter";
import { cn } from "@/lib/utils";

export type ButtonVariant = "primary" | "secondary" | "ghost" | "dark";
export type ButtonSize = "sm" | "md" | "lg";

const buttonBase = cn(
  "inline-flex cursor-pointer select-none items-center justify-center gap-2 rounded-xl font-semibold",
  "transition-[color,background-color,border-color,transform,box-shadow] duration-150 ease-out",
  "hover:-translate-y-0.5 active:translate-y-0 active:scale-[0.98] active:duration-75",
  "focus-ring disabled:pointer-events-none disabled:opacity-50 disabled:translate-y-0 disabled:active:scale-100 disabled:hover:translate-y-0",
  "whitespace-nowrap",
);

const buttonVariants: Record<ButtonVariant, string> = {
  primary:
    "border border-jade-600 bg-jade-500 text-white hover:bg-jade-600 hover:shadow-glow active:bg-jade-700",
  secondary:
    "border border-border bg-card text-foreground hover:border-jade-500/40 hover:bg-muted active:bg-accent",
  ghost: "border border-transparent text-foreground hover:bg-accent active:bg-accent",
  dark: "border border-ink-800 bg-ink-900 text-white hover:bg-ink-800 hover:shadow-glow active:bg-ink-850",
};

const buttonSizes: Record<ButtonSize, string> = {
  sm: "h-9 px-3.5 text-sm",
  md: "h-10 px-4 text-sm",
  lg: "h-12 px-5 text-[0.9375rem]",
};

export type ButtonProps = {
  variant?: ButtonVariant;
  size?: ButtonSize;
  className?: string;
} & (
  | ({ href: string } & Omit<React.ComponentProps<typeof Link>, "className" | "to" | "asChild">)
  | ({ href?: undefined } & Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, "className">)
);

export function Button({
  variant = "primary",
  size = "md",
  className,
  ...props
}: ButtonProps) {
  const classes = cn(buttonBase, buttonVariants[variant], buttonSizes[size], className);

  if ("href" in props && props.href !== undefined) {
    const { href, ...rest } = props;
    return <Link href={href} className={classes} {...rest} />;
  }

  const { type = "button", ...rest } = props as React.ButtonHTMLAttributes<HTMLButtonElement>;
  return <button type={type} className={classes} {...rest} />;
}
