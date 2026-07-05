import { Link, useLocation } from "wouter";
import { useAuth } from "@/hooks/use-auth";
import { useEffect } from "react";
import {
  House,
  UsersRound,
  PiggyBank,
  BookOpen,
  ArrowLeftRight,
} from "lucide-react";
import { Logo, MoolaMark } from "@/components/brand/Logo";
import { Avatar, Skeleton } from "@/components/ui";
import { NotificationBell } from "@/components/app/NotificationBell";
import { WalletSessionBanner } from "@/components/app/WalletSession";
import { ThemeToggle } from "@/components/app/ThemeToggle";
import { ShellNavList, type NavItem } from "@/components/app/ShellNav";
import { StreakIndicator } from "@/components/app/StreakFlame";
import { StreakMilestoneModal } from "@/components/app/StreakMilestoneModal";
import { useStreak } from "@/hooks/use-streak";
import { formatMoney, avatarSrc } from "@/lib/utils";
import { useGetDashboardSummary, useListNotifications, getGetDashboardSummaryQueryKey, getListNotificationsQueryKey } from "@workspace/api-client-react";

const nav: NavItem[] = [
  { label: "Home", href: "/", icon: House },
  { label: "Personal Savings", shortLabel: "Savings", href: "/goals", icon: PiggyBank },
  { label: "Group Savings", shortLabel: "Groups", href: "/circles", icon: UsersRound },
  { label: "Learn", href: "/learn", icon: BookOpen },
  { label: "Transactions", href: "/transactions", icon: ArrowLeftRight },
];

export function AppLayout({ children }: { children: React.ReactNode }) {
  const { user, isAuthenticated, isLoading: isAuthLoading } = useAuth();
  const [, setLocation] = useLocation();

  const { data: summary, isLoading: isSummaryLoading } = useGetDashboardSummary({
    query: { enabled: isAuthenticated, queryKey: getGetDashboardSummaryQueryKey() }
  });
  const { data: notifData } = useListNotifications({
    query: { enabled: isAuthenticated, queryKey: getListNotificationsQueryKey() }
  });
  const { data: streak } = useStreak(isAuthenticated);

  const needsCompletion = !!user && (!user.username || !user.hasPassword);

  useEffect(() => {
    if (!isAuthLoading && !isAuthenticated) {
      setLocation("/login");
    } else if (!isAuthLoading && isAuthenticated && needsCompletion) {
      setLocation("/complete-profile");
    }
  }, [isAuthLoading, isAuthenticated, needsCompletion, setLocation]);

  if (isAuthLoading || !isAuthenticated || needsCompletion) {
    return null;
  }

  const reminder = summary?.upcomingReminder;
  const notifications = (notifData?.notifications ?? []).map((n) => ({
    ...n,
    link: n.link ?? null,
  }));
  const unreadCount = notifData?.unreadCount ?? 0;

  return (
    <div className="min-h-[100dvh] bg-background">
      <aside className="fixed inset-y-0 left-0 z-30 hidden w-64 flex-col border-r border-border bg-card px-4 py-6 lg:flex">
        <Link href="/" className="px-2 transition-opacity hover:opacity-80">
          <Logo />
        </Link>

        <div className="mt-8">
          <ShellNavList items={nav} layout="sidebar" />
        </div>

        {reminder && (
          <div className="mt-6 rounded-xl border border-white/10 bg-ink-950 p-4 text-white">
            <p className="font-mono text-[10px] uppercase tracking-[0.18em] text-white/60">
              Next due
            </p>
            <p className="mt-1 text-sm font-semibold">{reminder.title}</p>
            <p className="text-xs text-white/70">
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
          className="mt-auto flex items-center gap-3 rounded-xl px-2 py-2 transition-colors duration-150 hover:bg-accent active:bg-accent"
        >
          {user ? (
            <Avatar name={user.name} src={avatarSrc(user.avatarUrl)} tone="jade" />
          ) : (
            <Skeleton className="h-9 w-9 rounded-full" />
          )}
          <div className="min-w-0">
            <p className="truncate text-sm font-semibold text-foreground">{user?.name ?? "…"}</p>
            <p className="truncate text-xs text-muted-foreground">View profile</p>
          </div>
        </Link>
      </aside>

      <div className="lg:pl-64">
        <header className="glass sticky top-0 z-20 rounded-none border-x-0 border-t-0">
          <div className="flex h-14 items-center justify-between gap-4 px-5 lg:h-16 lg:px-8">
            <Link href="/" className="lg:hidden">
              <MoolaMark className="h-8 w-8" />
            </Link>

            <Link
              href="/wallet"
              className="hover-lift flex items-center gap-2 rounded-xl border border-border bg-card px-3 py-1.5 hover:border-jade-500/40 sm:px-4 sm:py-2"
            >
              <span className="font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
                Balance
              </span>
              <span className="text-sm font-bold tabular-nums text-foreground">
                {isSummaryLoading ? "…" : formatMoney(summary?.totalCents ?? 0)}
              </span>
            </Link>

            <div className="flex items-center gap-2">
              <ThemeToggle className="hidden sm:inline-flex" />
              <NotificationBell notifications={notifications} unreadCount={unreadCount} />
              <StreakIndicator
                count={streak?.hero?.count ?? 0}
                status={streak?.hero?.status ?? "broken"}
              />
              <Link
                href="/profile"
                aria-label="View profile"
                className="ml-0.5 rounded-full ring-offset-2 ring-offset-background transition-shadow hover:ring-2 hover:ring-jade-500/40 focus-ring lg:hidden"
              >
                {user ? (
                  <Avatar name={user.name} src={avatarSrc(user.avatarUrl)} tone="jade" className="h-8 w-8" />
                ) : (
                  <Skeleton className="h-8 w-8 rounded-full" />
                )}
              </Link>
            </div>
          </div>
        </header>

        <main className="relative z-0 px-5 pb-[calc(4.5rem+env(safe-area-inset-bottom))] pt-6 lg:px-8 lg:pb-12">
          <WalletSessionBanner />
          {children}
        </main>
      </div>

      <nav className="glass fixed inset-x-0 bottom-0 z-50 rounded-t-3xl border-x-0 border-b-0 lg:hidden">
        <ShellNavList items={nav} layout="bottom" />
      </nav>

      <StreakMilestoneModal badges={streak?.badges} />
    </div>
  );
}
