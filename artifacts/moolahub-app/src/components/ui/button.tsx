import * as React from "react";
import { Link } from "wouter";
import { cn } from "@/lib/utils";

export type ButtonVariant = "primary" | "secondary" | "ghost" | "dark";
export type ButtonSize = "sm" | "md" | "lg";

const buttonBase = cn(
  "inline-flex cursor-pointer select-none items-center justify-center gap-2 rounded-xl font-semibold",
  "transition-[color,background-color,border-color,transform] duration-150 ease-out",
  "active:scale-[0.98] active:duration-75",
  "focus-ring disabled:pointer-events-none disabled:opacity-50 disabled:active:scale-100",
  "whitespace-nowrap",
);

const buttonVariants: Record<ButtonVariant, string> = {
  primary:
    "border border-jade-600 bg-jade-500 text-white hover:bg-jade-600 active:bg-jade-700",
  secondary:
    "border border-ink-900/12 bg-white text-ink-900 hover:border-ink-900/20 hover:bg-mist active:bg-ink-900/[0.04]",
  ghost: "border border-transparent text-ink-700 hover:bg-ink-900/[0.05] active:bg-ink-900/[0.08]",
  dark: "border border-ink-800 bg-ink-900 text-white hover:bg-ink-800 active:bg-ink-850",
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
