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
  TrendingUp,
} from "lucide-react";
import {
  GlassCard,
  MetricCard,
  ProgressLine,
  GlowLineChart,
  Button,
  Badge,
  IconChip,
  Eyebrow,
  Skeleton,
} from "@/components/ui";
import { Money } from "@/components/app/bits";
import { useGetDashboardSummary, useGetMe } from "@workspace/api-client-react";
import { useStreak } from "@/hooks/use-streak";
import { streakVisual } from "@/components/app/StreakFlame";
import { formatMoney, pct, timeAgo, formatDate } from "@/lib/utils";
import { useTranslation } from "react-i18next";

const YIELD_APY = 0.041;

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
  const { data: summary, isLoading } = useGetDashboardSummary();
  const { data: streak } = useStreak();

  const firstName = user?.name?.split(" ")[0] ?? "";

  if (isLoading || !summary) {
    return (
      <div className="mx-auto max-w-6xl space-y-6">
        <Skeleton className="h-10 w-56" />
        <div className="grid gap-6 lg:grid-cols-3">
          <Skeleton className="h-72 lg:col-span-2" />
          <Skeleton className="h-72" />
        </div>
        <div className="grid gap-4 sm:grid-cols-3">
          <Skeleton className="h-28" />
          <Skeleton className="h-28" />
          <Skeleton className="h-28" />
        </div>
        <Skeleton className="h-56 w-full" />
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
  } = summary;

  const activeCircle = activeCircles.find((c) => c.status === "active") ?? activeCircles[0];

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
        <div className="mh-card-highlight relative isolate overflow-hidden rounded-[var(--mh-radius-lg)] p-6 text-white lg:col-span-2 lg:p-8">
          <GlowLineChart
            className="pointer-events-none absolute inset-x-0 bottom-0 -z-10 h-40 w-full opacity-70"
          />

          <div className="flex flex-wrap items-start justify-between gap-4">
            <div>
              <p className="font-mono text-[10px] uppercase tracking-[0.2em] text-white/70">
                {t("hero.totalBalance")}
              </p>
              <p className="mt-1.5 font-display text-4xl font-bold tracking-[-0.04em] sm:text-5xl">
                <Money cents={totalCents} />
              </p>
            </div>
            <span className="inline-flex items-center gap-1.5 rounded-full border border-white/25 bg-white/15 px-2.5 py-1 text-xs font-semibold text-white">
              <TrendingUp className="h-3.5 w-3.5" />
              {t("hero.apy", { apy: (YIELD_APY * 100).toFixed(1) })}
            </span>
          </div>

          <div className="mt-8 flex flex-wrap gap-3">
            <Button
              href="/wallet"
              size="md"
              className="border-white/30 bg-white text-jade-700 shadow-none hover:bg-white/90 hover:brightness-100"
            >
              {t("hero.addMoney")}
            </Button>
            <Button
              href="/wallet"
              size="md"
              variant="secondary"
              className="border-white/25 bg-white/10 text-white hover:bg-white/20"
            >
              {t("hero.withdraw")}
            </Button>
          </div>

          <div className="mt-6 rounded-2xl border border-white/15 bg-white/[0.06] p-4 backdrop-blur-sm">
            <div className="flex items-center justify-between text-xs text-white/75">
              <span className="font-mono uppercase tracking-[0.15em]">{t("hero.growthLabel")}</span>
              <span className="font-semibold text-white">
                {t("hero.earned", { amount: formatMoney(Math.floor(totalCents * YIELD_APY), { sign: true }) })}
              </span>
            </div>
          </div>
        </div>

        {/* --------------------------------------------------- Reminders */}
        <GlassCard className="flex flex-col">
          <div className="flex items-center justify-between">
            <h2 className="font-display text-lg font-bold text-foreground">{t("reminders.title")}</h2>
            <IconChip tone="jade" className="h-9 w-9">
              <Bell className="h-4 w-4" />
            </IconChip>
          </div>
          <ul className="mt-4 flex-1 space-y-3">
            {!upcomingReminder ? (
              <li className="flex h-full items-center justify-center rounded-2xl border border-dashed border-[var(--mh-border)] px-4 py-6 text-center text-sm text-muted-foreground">
                {t("reminders.allCaughtUp")}
              </li>
            ) : (
              <li className="mh-glass flex items-center justify-between rounded-2xl px-4 py-3">
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
        </GlassCard>
      </div>

      {/* ----------------------------------------------------- Metric row */}
      <div className="grid gap-4 sm:grid-cols-3">
        <MetricCard
          label={t("hero.available")}
          value={<Money cents={availableCents} />}
          icon={<Sparkles className="h-5 w-5" />}
        />
        <MetricCard
          label={t("hero.inSavings")}
          value={<Money cents={goalTotalCents} />}
          icon={<PiggyBank className="h-5 w-5" />}
        />
        <MetricCard
          label={t("hero.growthLabel")}
          value={t("hero.apy", { apy: (YIELD_APY * 100).toFixed(1) })}
          helper={t("hero.earned", { amount: formatMoney(Math.floor(totalCents * YIELD_APY), { sign: true }) })}
          icon={<TrendingUp className="h-5 w-5" />}
        />
      </div>

      {/* ----------------------------------------------------- Savings streak */}
      {streak && (
        <Link href="/streaks" className="block">
          <GlassCard hover className="flex items-center justify-between gap-4">
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
          </GlassCard>
        </Link>
      )}

      {/* ----------------------------------------- Goals + Circle + Learn */}
      <div className="grid gap-6 lg:grid-cols-3">
        <GlassCard hover>
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-3">
              <IconChip tone="jade">
                <PiggyBank className="h-5 w-5" />
              </IconChip>
              <h2 className="font-display text-lg font-bold text-foreground">{t("savings.title")}</h2>
            </div>
            <Link href="/goals" className="text-muted-foreground transition-colors hover:text-foreground focus-ring rounded-full">
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
                  <span className="font-medium text-foreground transition-colors group-hover:text-jade-600 dark:group-hover:text-jade-400">
                    {g.emoji} {g.name}
                  </span>
                  <span className="text-muted-foreground">{pct(g.savedCents, g.targetCents)}%</span>
                </div>
                <ProgressLine value={pct(g.savedCents, g.targetCents)} className="mt-2" />
              </Link>
            ))}
          </div>
        </GlassCard>

        <GlassCard hover>
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-3">
              <IconChip tone="jade">
                <UsersRound className="h-5 w-5" />
              </IconChip>
              <h2 className="font-display text-lg font-bold text-foreground">{t("circle.title")}</h2>
            </div>
            <Link href="/circles" className="text-muted-foreground transition-colors hover:text-foreground focus-ring rounded-full">
              <ChevronRight className="h-5 w-5 rtl:rotate-180" />
            </Link>
          </div>
          {activeCircle ? (
            <Link href={`/circles/${activeCircle.id}`} className="mt-5 block group">
              <p className="font-semibold text-foreground transition-colors group-hover:text-jade-600 dark:group-hover:text-jade-400">
                {activeCircle.name}
              </p>
              <p className="text-sm capitalize text-muted-foreground">
                {t("circle.round", {
                  current: activeCircle.currentRound,
                  total: activeCircle.totalRounds,
                  frequency: t(`frequency.${activeCircle.frequency}`, { defaultValue: activeCircle.frequency }),
                })}
              </p>
              <div className="mh-glass mt-4 flex items-center justify-between rounded-2xl px-4 py-3">
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
        </GlassCard>

        <GlassCard hover className="flex flex-col">
          <div className="flex items-center gap-3">
            <IconChip tone="amber">
              <BookOpen className="h-5 w-5" />
            </IconChip>
            <h2 className="font-display text-lg font-bold text-foreground">{t("learn.title")}</h2>
          </div>
          <div className="mt-5 flex-1">
            <span className="text-3xl">⛓️</span>
            <p className="mt-3 font-semibold leading-snug text-foreground">{t("learn.lessonTitle")}</p>
            <p className="mt-1 font-mono text-xs uppercase tracking-wide text-muted-foreground">
              {t("learn.lessonMeta")}
            </p>
          </div>
          <Button
            href={`/learn/understanding-blockchain`}
            variant="secondary"
            size="sm"
            className="mt-5 w-full"
          >
            {t("learn.startLesson")}
          </Button>
        </GlassCard>
      </div>

      {/* ---------------------------------------------------- Recent transactions */}
      <GlassCard>
        <div className="flex items-center justify-between">
          <h2 className="font-display text-lg font-bold text-foreground">{t("transactions.title")}</h2>
          <Link
            href="/transactions"
            className="text-sm font-medium text-jade-600 transition-colors hover:text-jade-700 focus-ring rounded-lg dark:text-jade-400"
          >
            {t("transactions.viewAll")}
          </Link>
        </div>
        <ul className="mt-4 divide-y divide-[var(--mh-border)]">
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
      </GlassCard>
    </div>
  );
}
