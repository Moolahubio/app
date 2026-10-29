import { Link } from "wouter";
import {
  ArrowUpRight,
  ArrowDownLeft,
  Sparkles,
  UsersRound,
  PiggyBank,
  BookOpen,
  Bell,
  ChevronRight,
} from "lucide-react";
import { Card, Button, Badge, ProgressBar, IconChip, Eyebrow, Skeleton } from "@/components/ui";
import { Money, BalanceFooter, LoadError } from "@/components/app/bits";
import { useGetDashboardSummary, useGetMe } from "@workspace/api-client-react";
import { useStreak } from "@/hooks/use-streak";
import { streakVisual } from "@/components/app/StreakFlame";
import { pct, timeAgo, formatDate } from "@/lib/utils";
import { useTranslation } from "react-i18next";

// The featured lesson is a savings one; plumbing lessons are an opt-in track.
const FEATURED_LESSON = { slug: "setting-savings-goals", emoji: "🎯" };

const activityIcon: Record<string, typeof ArrowDownLeft> = {
  deposit: ArrowDownLeft,
  payout: ArrowDownLeft,
  yield: Sparkles,
  contribution: ArrowUpRight,
  goal_allocate: PiggyBank,
  goal_release: PiggyBank,
  withdrawal: ArrowUpRight,
};

function streakFreqKey(frequency: string): "daily" | "weekly" | "biweekly" | "monthly" {
  if (frequency === "daily" || frequency === "monthly" || frequency === "biweekly") return frequency;
  return "weekly";
}

export default function DashboardPage() {
  const { t } = useTranslation("dashboard");
  const { data: user } = useGetMe();
  const { data: summary, isLoading, isError, refetch } = useGetDashboardSummary();
  const { data: streak } = useStreak();

  const firstName = user?.name?.split(" ")[0] ?? "";

  // A failed load must never read as a $0 balance or spin forever.
  if (!summary && isError && !isLoading) {
    return (
      <Card className="mx-auto max-w-6xl">
        <LoadError onRetry={() => void refetch()} />
      </Card>
    );
  }

  if (isLoading || !summary) {
    return (
      <div className="mx-auto max-w-6xl space-y-6">
        <Skeleton className="h-10 w-48" />
        <Skeleton className="h-64 w-full" />
      </div>
    );
  }

  const {
    totalCents,
    availableCents,
    goalTotalCents,
    recentActivity,
    activeGoals,
    activeCircles,
    upcomingReminder,
    balanceUnavailable,
  } = summary;

  // activeCircles also lists forming groups; this card shows an active one only.
  const activeCircle = activeCircles.find((c) => c.status === "active");

  return (
    <div className="mx-auto max-w-6xl space-y-6">
      <div>
        <Eyebrow>{t("hero.eyebrow")}</Eyebrow>
        <h1 className="mt-1.5 font-display text-3xl font-bold tracking-tight text-foreground">
          {firstName ? t("hero.greetingNamed", { name: firstName }) : t("hero.greeting")}
        </h1>
      </div>

      <div className="grid gap-6 lg:grid-cols-3">
        {/* ---------------------------------------------- Balance hero card */}
        <Card className="relative overflow-hidden border-ink-900 bg-ink-950 p-6 text-white lg:col-span-2 lg:p-8">
          <div
            className="pointer-events-none absolute inset-0 bg-grid-dark [background-size:32px_32px] opacity-35"
            aria-hidden
          />

          <div className="relative z-10 flex flex-wrap items-start justify-between gap-4">
            <div>
              <p className="font-mono text-[10px] uppercase tracking-[0.2em] text-white/60">
                {t("hero.totalBalance")}
              </p>
              <p className="mt-1.5 font-display text-4xl font-bold sm:text-5xl">
                <Money cents={totalCents} />
              </p>
              <div className="mt-3 flex flex-wrap gap-x-5 gap-y-1 text-sm text-white/70">
                <span>
                  {t("hero.available")}{" "}
                  <Money cents={availableCents} className="font-semibold text-white" />
                </span>
                <span>
                  {t("hero.inSavings")}{" "}
                  <Money cents={goalTotalCents} className="font-semibold text-white" />
                </span>
              </div>
              {balanceUnavailable && (
                <p className="mt-2 text-xs text-amber-300">{t("common:states.balanceStale")}</p>
              )}
            </div>
          </div>

          <div className="relative z-10 mt-6 flex flex-wrap gap-3">
            <Button href="/wallet" size="sm">
              {t("hero.addMoney")}
            </Button>
            <Button
              href="/wallet"
              size="sm"
              variant="secondary"
              className="border-white/15 bg-white/10 text-white hover:bg-white/15"
            >
              {t("hero.withdraw")}
            </Button>
          </div>

          <BalanceFooter tone="onDark" className="relative z-10 mt-6" />
        </Card>

        {/* --------------------------------------------------- Reminders */}
        <Card className="flex flex-col p-6">
          <div className="flex items-center justify-between">
            <h2 className="font-display text-lg font-bold text-foreground">{t("reminders.title")}</h2>
            <IconChip tone="jade" className="h-9 w-9">
              <Bell className="h-4 w-4" />
            </IconChip>
          </div>
          <ul className="mt-4 flex-1 space-y-3">
            {!upcomingReminder ? (
              <li className="rounded-2xl border border-dashed border-border px-4 py-6 text-center text-sm text-muted-foreground">
                {t("reminders.allCaughtUp")}
              </li>
            ) : (
              <li className="flex items-center justify-between rounded-2xl border border-border bg-background px-4 py-3">
                <div className="min-w-0">
                  <p className="truncate text-sm font-semibold text-foreground">{upcomingReminder.title}</p>
                </div>
                <div className="text-end">
                  <p className="text-sm font-semibold text-foreground">
                    <Money cents={upcomingReminder.amountCents} compact />
                  </p>
                  <p className="font-mono text-[10px] uppercase tracking-wide text-jade-600 dark:text-jade-400">
                    {formatDate(upcomingReminder.dueDate, { month: "short", day: "numeric" })}
                  </p>
                </div>
              </li>
            )}
          </ul>
        </Card>
      </div>

      {/* ----------------------------------------------------- Savings streak */}
      {streak && (
        <Link href="/streaks" className="block">
          <Card className="flex items-center justify-between gap-4 p-5 transition-colors hover:bg-accent">
            <div className="flex items-center gap-4">
              {(() => {
                const count = streak.hero?.count ?? 0;
                const status = streak.hero?.status ?? "broken";
                const v = streakVisual(status, count);
                return (
                  <span className={`flex h-12 w-12 items-center justify-center rounded-2xl ${v.glow}`}>
                    <v.Icon className={`h-6 w-6 ${v.color}`} />
                  </span>
                );
              })()}
              <div>
                <p className="font-display text-lg font-bold text-foreground">
                  {streak.hero
                    ? t(`streak.count.${streakFreqKey(streak.frequency)}`, { count: streak.hero.count })
                    : t("streak.none")}
                </p>
                <p className="text-sm text-muted-foreground">
                  {streak.hero
                    ? streak.currentPeriodSatisfied
                      ? t(`streak.saved.${streakFreqKey(streak.frequency)}`)
                      : t(`streak.keepAlive.${streakFreqKey(streak.frequency)}`)
                    : t("streak.firstFlame")}
                </p>
              </div>
            </div>
            <ChevronRight className="h-5 w-5 shrink-0 text-muted-foreground rtl:rotate-180" />
          </Card>
        </Link>
      )}

      {/* ----------------------------------------- Goals + Circle + Learn */}
      <div className="grid gap-6 lg:grid-cols-3">
        <Card className="p-6">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-3">
              <IconChip tone="jade">
                <PiggyBank className="h-5 w-5" />
              </IconChip>
              <h2 className="font-display text-lg font-bold text-foreground">{t("savings.title")}</h2>
            </div>
            <Link href="/goals" className="text-muted-foreground transition-colors hover:text-muted-foreground">
              <ChevronRight className="h-5 w-5 rtl:rotate-180" />
            </Link>
          </div>
          <div className="mt-5 space-y-4">
            {activeGoals.length === 0 && (
              <p className="text-sm text-muted-foreground">{t("savings.empty")}</p>
            )}
            {activeGoals.slice(0, 3).map((g) => (
              <Link key={g.id} href={`/goals/${g.id}`} className="block group">
                <div className="flex items-center justify-between text-sm">
                  <span className="font-medium text-foreground group-hover:text-jade-600 dark:group-hover:text-jade-400 transition-colors">
                    {g.emoji} {g.name}
                  </span>
                  <span className="text-muted-foreground">{pct(g.savedCents, g.targetCents)}%</span>
                </div>
                <ProgressBar value={g.savedCents} total={g.targetCents} className="mt-2" />
              </Link>
            ))}
          </div>
        </Card>

        <Card className="p-6">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-3">
              <IconChip tone="jade">
                <UsersRound className="h-5 w-5" />
              </IconChip>
              <h2 className="font-display text-lg font-bold text-foreground">{t("circle.title")}</h2>
            </div>
            <Link href="/circles" className="text-muted-foreground transition-colors hover:text-muted-foreground">
              <ChevronRight className="h-5 w-5 rtl:rotate-180" />
            </Link>
          </div>
          {activeCircle ? (
            <Link href={`/circles/${activeCircle.id}`} className="mt-5 block group">
              <p className="font-semibold text-foreground group-hover:text-jade-600 dark:group-hover:text-jade-400 transition-colors">{activeCircle.name}</p>
              <p className="text-sm capitalize text-muted-foreground">
                {t("circle.round", {
                  current: activeCircle.currentRound,
                  total: activeCircle.totalRounds,
                  frequency: t(`frequency.${activeCircle.frequency}`, { defaultValue: activeCircle.frequency }),
                })}
              </p>
              <div className="mt-4 flex items-center justify-between rounded-2xl bg-background px-4 py-3">
                <div>
                  <p className="font-mono text-[10px] uppercase tracking-wide text-muted-foreground">{t("circle.pot")}</p>
                  <p className="font-semibold text-foreground"><Money cents={activeCircle.potCents} /></p>
                </div>
                <Badge tone="jade">{t("circle.members", { count: activeCircle.memberCount })}</Badge>
              </div>
            </Link>
          ) : (
            <p className="mt-5 text-sm text-muted-foreground">{t("circle.empty")}</p>
          )}
        </Card>

        <Card className="flex flex-col p-6">
          <div className="flex items-center gap-3">
            <IconChip tone="amber">
              <BookOpen className="h-5 w-5" />
            </IconChip>
            <h2 className="font-display text-lg font-bold text-foreground">{t("learn.title")}</h2>
          </div>
          <div className="mt-5 flex-1">
            <span className="text-3xl">{FEATURED_LESSON.emoji}</span>
            <p className="mt-3 font-semibold leading-snug text-foreground">{t("learn.lessonTitle")}</p>
            <p className="mt-1 font-mono text-xs uppercase tracking-wide text-muted-foreground">
              {t("learn.lessonMeta")}
            </p>
          </div>
          <Button
            href={`/learn/${FEATURED_LESSON.slug}`}
            variant="secondary"
            size="sm"
            className="mt-5 w-full"
          >
            {t("learn.startLesson")}
          </Button>
        </Card>
      </div>

      {/* ---------------------------------------------------- Recent transactions */}
      <Card className="p-6">
        <div className="flex items-center justify-between">
          <h2 className="font-display text-lg font-bold text-foreground">{t("transactions.title")}</h2>
          <Link href="/transactions" className="text-sm font-medium text-jade-600 dark:text-jade-400 hover:text-jade-700">
            {t("transactions.viewAll")}
          </Link>
        </div>
        <ul className="mt-4 divide-y divide-border">
          {recentActivity.length === 0 && (
            <li className="py-6 text-center text-sm text-muted-foreground">{t("transactions.empty")}</li>
          )}
          {recentActivity.slice(0, 5).map((item) => {
            const Icon = activityIcon[item.type] ?? ArrowUpRight;
            const positive = (item.amountCents ?? 0) > 0;
            return (
              <li key={item.id} className="flex items-center gap-4 py-3">
                <IconChip tone={positive ? "jade" : "ink"} className="h-10 w-10">
                  <Icon className="h-5 w-5" />
                </IconChip>
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-semibold text-foreground">{item.description}</p>
                  <p className="truncate text-xs text-muted-foreground">
                    {timeAgo(item.createdAt)}
                  </p>
                </div>
                {item.amountCents != null && (
                  <p
                    className={`text-sm font-semibold ${positive ? "text-jade-600 dark:text-jade-400" : "text-foreground"}`}
                  >
                    <Money cents={item.amountCents} sign />
                  </p>
                )}
              </li>
            );
          })}
        </ul>
      </Card>
    </div>
  );
}
