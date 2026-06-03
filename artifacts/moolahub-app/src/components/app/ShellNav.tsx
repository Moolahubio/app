import { Link, useLocation } from "wouter";
import type { LucideIcon } from "lucide-react";
import { cn } from "@/lib/utils";

export type NavItem = {
  label: string;
  href: string;
  icon: LucideIcon;
};

function isActive(pathname: string, href: string) {
  if (href === "/") return pathname === "/";
  return pathname.startsWith(href);
}

export function ShellNavList({
  items,
  layout,
}: {
  items: NavItem[];
  layout: "sidebar" | "bottom";
}) {
  const [pathname] = useLocation();

  if (layout === "bottom") {
    return (
      <div className="mx-auto grid max-w-md grid-cols-5 safe-pb">
        {items.map((item) => (
          <ShellNavLink key={item.href} item={item} active={isActive(pathname, item.href)} layout="bottom" />
        ))}
      </div>
    );
  }

  return (
    <nav className="flex-1 space-y-0.5">
      {items.map((item) => (
        <ShellNavLink key={item.href} item={item} active={isActive(pathname, item.href)} layout="sidebar" />
      ))}
    </nav>
  );
}

function ShellNavLink({
  item,
  active,
  layout,
}: {
  item: NavItem;
  active: boolean;
  layout: "sidebar" | "bottom";
}) {
  const Icon = item.icon;

  if (layout === "bottom") {
    return (
      <Link
        href={item.href}
        className={cn(
          "relative flex flex-col items-center gap-1 py-2.5 text-[10px] font-medium transition-colors duration-150",
          "active:opacity-70",
          active ? "text-jade-600" : "text-ink-400",
        )}
      >
        {active && (
          <span
            className="absolute top-0 h-0.5 w-8 rounded-full bg-jade-500 transition-all duration-200"
            aria-hidden
          />
        )}
        <Icon className={cn("h-5 w-5 transition-transform duration-150", active && "scale-105")} strokeWidth={active ? 2.25 : 2} />
        {item.label}
      </Link>
    );
  }

  return (
    <Link
      href={item.href}
      className={cn(
        "group relative flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-medium transition-colors duration-150",
        "active:bg-ink-900/[0.06]",
        active ? "text-jade-800" : "text-ink-500 hover:bg-ink-900/[0.04] hover:text-ink-900",
      )}
    >
      {active && (
        <span
          className="absolute inset-y-1.5 left-0 w-0.5 rounded-full bg-jade-500 transition-all duration-200"
          aria-hidden
        />
      )}
      <Icon
        className={cn(
          "h-5 w-5 shrink-0 transition-colors duration-150",
          active ? "text-jade-600" : "text-ink-400 group-hover:text-ink-600",
        )}
        strokeWidth={active ? 2.25 : 2}
      />
      {item.label}
    </Link>
  );
}
