"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import {
  LayoutDashboard,
  Users,
  Target,
  GraduationCap,
  Receipt,
  Bell,
  Plus,
} from "lucide-react";
import { Logo, MoolaMark } from "@/components/brand/Logo";
import { Avatar, Button } from "@/components/ui";
import { formatMoney, cn } from "@/lib/utils";

const nav = [
  { label: "Home", href: "/", icon: LayoutDashboard },
  { label: "Circles", href: "/circles", icon: Users },
  { label: "Goals", href: "/goals", icon: Target },
  { label: "Learn", href: "/learn", icon: GraduationCap },
  { label: "Activity", href: "/activity", icon: Receipt },
];

function isActive(pathname: string, href: string) {
  if (href === "/") return pathname === "/";
  return pathname.startsWith(href);
}

export type ShellProps = {
  user: { name: string; kycStatus: string };
  balanceCents: number;
  reminder: { title: string; amountCents: number; dueDate: string } | null;
  children: React.ReactNode;
};

export function AppShell({ user, balanceCents, reminder, children }: ShellProps) {
  const pathname = usePathname();
  const kycLabel =
    user.kycStatus === "verified"
      ? "Verified · KYC"
      : user.kycStatus === "pending"
        ? "KYC pending"
        : "KYC required";

  return (
    <div className="min-h-screen bg-mist">
      {/* ----------------------------------------------------- Sidebar (lg) */}
      <aside className="fixed inset-y-0 left-0 z-40 hidden w-64 flex-col border-r border-ink-900/[0.07] bg-white px-4 py-6 lg:flex">
        <Link href="/" className="px-2">
          <Logo />
        </Link>

        <nav className="mt-8 flex-1 space-y-1">
          {nav.map((item) => {
            const active = isActive(pathname, item.href);
            return (
              <Link
                key={item.href}
                href={item.href}
                className={cn(
                  "flex items-center gap-3 rounded-2xl px-3 py-2.5 text-sm font-medium transition-colors",
                  active
                    ? "bg-jade-50 text-jade-700"
                    : "text-ink-500 hover:bg-ink-900/[0.04] hover:text-ink-900",
                )}
              >
                <item.icon className={cn("h-5 w-5", active && "text-jade-600")} />
                {item.label}
              </Link>
            );
          })}
        </nav>

        {/* upcoming reminder card */}
        {reminder && (
          <div className="rounded-2xl bg-ink-950 p-4 text-white">
            <p className="font-mono text-[10px] uppercase tracking-[0.18em] text-white/45">
              Next due
            </p>
            <p className="mt-1 text-sm font-semibold">{reminder.title}</p>
            <p className="text-xs text-white/55">
              {formatMoney(reminder.amountCents)} ·{" "}
              {new Date(reminder.dueDate).toLocaleDateString("en-US", {
                month: "short",
                day: "numeric",
              })}
            </p>
          </div>
        )}

        <Link
          href="/profile"
          className="mt-4 flex items-center gap-3 rounded-2xl px-2 py-2 transition-colors hover:bg-ink-900/[0.04]"
        >
          <Avatar name={user.name} tone="jade" />
          <div className="min-w-0">
            <p className="truncate text-sm font-semibold text-ink-900">{user.name}</p>
            <p className="truncate text-xs text-ink-400">{kycLabel}</p>
          </div>
        </Link>
      </aside>

      {/* --------------------------------------------------------- Main col */}
      <div className="lg:pl-64">
        {/* topbar */}
        <header className="sticky top-0 z-30 border-b border-ink-900/[0.07] bg-mist/80 backdrop-blur">
          <div className="flex h-16 items-center justify-between gap-4 px-5 lg:px-8">
            <Link href="/" className="lg:hidden">
              <MoolaMark className="h-8 w-8" />
            </Link>

            <div className="hidden items-center gap-2 rounded-full border border-ink-900/[0.08] bg-white px-4 py-2 lg:flex">
              <span className="font-mono text-[10px] uppercase tracking-[0.18em] text-ink-400">
                Balance
              </span>
              <span className="text-sm font-bold text-ink-900">{formatMoney(balanceCents)}</span>
            </div>

            <div className="flex items-center gap-2">
              <button
                className="relative inline-flex h-10 w-10 items-center justify-center rounded-full border border-ink-900/[0.08] bg-white text-ink-600 transition-colors hover:text-ink-900 focus-ring"
                aria-label="Reminders"
              >
                <Bell className="h-5 w-5" />
                {reminder && (
                  <span className="absolute right-2.5 top-2.5 h-2 w-2 rounded-full bg-jade-500 ring-2 ring-white" />
                )}
              </button>
              <Button href="/goals/new" size="sm" className="hidden sm:inline-flex">
                <Plus className="h-4 w-4" /> New goal
              </Button>
            </div>
          </div>
        </header>

        <main className="px-5 pb-28 pt-6 lg:px-8 lg:pb-12">{children}</main>
      </div>

      {/* ------------------------------------------------ Mobile bottom nav */}
      <nav className="fixed inset-x-0 bottom-0 z-40 border-t border-ink-900/[0.07] bg-white/95 backdrop-blur lg:hidden">
        <div className="mx-auto grid max-w-md grid-cols-5">
          {nav.map((item) => {
            const active = isActive(pathname, item.href);
            return (
              <Link
                key={item.href}
                href={item.href}
                className={cn(
                  "flex flex-col items-center gap-1 py-3 text-[10px] font-medium transition-colors",
                  active ? "text-jade-600" : "text-ink-400",
                )}
              >
                <item.icon className="h-5 w-5" />
                {item.label}
              </Link>
            );
          })}
        </div>
      </nav>
    </div>
  );
}
