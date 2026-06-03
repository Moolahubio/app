import { Link } from "wouter";
import {
  ArrowUpRight,
  ArrowDownLeft,
  Sparkles,
  Users,
  Target,
  GraduationCap,
  Bell,
  ChevronRight,
  TrendingUp,
} from "lucide-react";
import { Card, Button, Badge, ProgressBar, IconChip, Eyebrow, Skeleton } from "@/components/ui";
import { AscendingChart } from "@/components/marketing/AscendingChart";
import { useGetDashboardSummary, useGetMe } from "@workspace/api-client-react";
import { formatMoney, pct, timeAgo } from "@/lib/utils";

const YIELD_APY = 0.041;

const activityIcon: Record<string, typeof ArrowDownLeft> = {
  deposit: ArrowDownLeft,
  payout: ArrowDownLeft,
  yield: Sparkles,
  contribution: ArrowUpRight,
  goal_allocate: Target,
  goal_release: Target,
  withdrawal: ArrowUpRight,
};

export default function DashboardPage() {
  const { data: user } = useGetMe();
  const { data: summary, isLoading } = useGetDashboardSummary();

  const firstName = user?.name?.split(" ")[0] ?? "";

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
    upcomingReminder
  } = summary;

  const activeCircle = activeCircles.find((c) => c.status === "active") ?? activeCircles[0];

  return (
    <div className="mx-auto max-w-6xl space-y-6">
      <div>
        <Eyebrow>Welcome back</Eyebrow>
        <h1 className="mt-1.5 font-display text-3xl font-bold tracking-tight text-ink-900">
          Good to see you{firstName ? `, ${firstName}` : ""}
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
              <p className="font-mono text-[10px] uppercase tracking-[0.2em] text-white/45">
                Total balance
              </p>
              <p className="mt-1.5 font-display text-4xl font-bold sm:text-5xl">
                {formatMoney(totalCents)}
              </p>
              <div className="mt-3 flex flex-wrap gap-x-5 gap-y-1 text-sm text-white/55">
                <span>
                  Available{" "}
                  <span className="font-semibold text-white">
                    {formatMoney(availableCents)}
                  </span>
                </span>
                <span>
                  In goals{" "}
                  <span className="font-semibold text-white">
                    {formatMoney(goalTotalCents)}
                  </span>
                </span>
              </div>
            </div>
            <Badge tone="jade" className="bg-jade-500/15 text-jade-300 ring-jade-400/20">
              <TrendingUp className="h-3.5 w-3.5" /> +{(YIELD_APY * 100).toFixed(1)}% APY
            </Badge>
          </div>

          <div className="relative z-10 mt-6 flex flex-wrap gap-3">
            <Button href="/wallet" size="sm">
              Add money
            </Button>
            <Button
              href="/wallet"
              size="sm"
              variant="secondary"
              className="border-white/15 bg-white/10 text-white hover:bg-white/15"
            >
              Withdraw
            </Button>
          </div>

          <div className="relative z-10 mt-6 rounded-2xl border border-white/10 bg-white/[0.03] p-4">
            <div className="flex items-center justify-between text-xs text-white/50">
              <span className="font-mono uppercase tracking-[0.15em]">Growth · 6 months</span>
              <span className="text-jade-400">
                +{formatMoney(Math.floor(totalCents * YIELD_APY), { sign: true })} earned
              </span>
            </div>
            <AscendingChart className="mt-1 max-h-28" />
          </div>
        </Card>

        {/* --------------------------------------------------- Reminders */}
        <Card className="flex flex-col p-6">
          <div className="flex items-center justify-between">
            <h2 className="font-display text-lg font-bold text-ink-900">Coming up</h2>
            <IconChip tone="jade" className="h-9 w-9">
              <Bell className="h-4 w-4" />
            </IconChip>
          </div>
          <ul className="mt-4 flex-1 space-y-3">
            {!upcomingReminder ? (
              <li className="rounded-2xl border border-dashed border-ink-900/10 px-4 py-6 text-center text-sm text-ink-400">
                You&apos;re all caught up.
              </li>
            ) : (
              <li className="flex items-center justify-between rounded-2xl border border-ink-900/[0.06] bg-mist px-4 py-3">
                <div className="min-w-0">
                  <p className="truncate text-sm font-semibold text-ink-900">{upcomingReminder.title}</p>
                </div>
                <div className="text-right">
                  <p className="text-sm font-semibold text-ink-900">
                    {formatMoney(upcomingReminder.amountCents, { compact: true })}
                  </p>
                  <p className="font-mono text-[10px] uppercase tracking-wide text-jade-600">
                    {new Date(upcomingReminder.dueDate).toLocaleDateString("en-US", { month: "short", day: "numeric" })}
                  </p>
                </div>
              </li>
            )}
          </ul>
        </Card>
      </div>

      {/* ----------------------------------------- Goals + Circle + Learn */}
      <div className="grid gap-6 lg:grid-cols-3">
        <Card className="p-6">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-3">
              <IconChip tone="jade">
                <Target className="h-5 w-5" />
              </IconChip>
              <h2 className="font-display text-lg font-bold text-ink-900">Your goals</h2>
            </div>
            <Link href="/goals" className="text-ink-300 transition-colors hover:text-ink-600">
              <ChevronRight className="h-5 w-5" />
            </Link>
          </div>
          <div className="mt-5 space-y-4">
            {activeGoals.length === 0 && (
              <p className="text-sm text-ink-400">No goals yet — create your first one.</p>
            )}
            {activeGoals.slice(0, 3).map((g) => (
              <Link key={g.id} href={`/goals/${g.id}`} className="block group">
                <div className="flex items-center justify-between text-sm">
                  <span className="font-medium text-ink-800 group-hover:text-jade-600 transition-colors">
                    {g.emoji} {g.name}
                  </span>
                  <span className="text-ink-400">{pct(g.savedCents, g.targetCents)}%</span>
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
                <Users className="h-5 w-5" />
              </IconChip>
              <h2 className="font-display text-lg font-bold text-ink-900">Active circle</h2>
            </div>
            <Link href="/circles" className="text-ink-300 transition-colors hover:text-ink-600">
              <ChevronRight className="h-5 w-5" />
            </Link>
          </div>
          {activeCircle ? (
            <Link href={`/circles/${activeCircle.id}`} className="mt-5 block group">
              <p className="font-semibold text-ink-900 group-hover:text-jade-600 transition-colors">{activeCircle.name}</p>
              <p className="text-sm capitalize text-ink-500">
                Round {activeCircle.currentRound} of {activeCircle.totalRounds} ·{" "}
                {activeCircle.frequency}
              </p>
              <div className="mt-4 flex items-center justify-between rounded-2xl bg-mist px-4 py-3">
                <div>
                  <p className="font-mono text-[10px] uppercase tracking-wide text-ink-400">Pot</p>
                  <p className="font-semibold text-ink-900">{formatMoney(activeCircle.potCents)}</p>
                </div>
                <Badge tone="jade">{activeCircle.memberCount} members</Badge>
              </div>
            </Link>
          ) : (
            <p className="mt-5 text-sm text-ink-400">No active circles yet.</p>
          )}
        </Card>

        <Card className="flex flex-col p-6">
          <div className="flex items-center gap-3">
            <IconChip tone="amber">
              <GraduationCap className="h-5 w-5" />
            </IconChip>
            <h2 className="font-display text-lg font-bold text-ink-900">Keep learning</h2>
          </div>
          <div className="mt-5 flex-1">
            <span className="text-3xl">⛓️</span>
            <p className="mt-3 font-semibold leading-snug text-ink-900">Understanding Blockchain (Simply)</p>
            <p className="mt-1 font-mono text-xs uppercase tracking-wide text-ink-400">
              5 min · Beginner
            </p>
          </div>
          <Button
            href={`/learn/understanding-blockchain`}
            variant="secondary"
            size="sm"
            className="mt-5 w-full"
          >
            Start lesson
          </Button>
        </Card>
      </div>

      {/* ---------------------------------------------------- Recent activity */}
      <Card className="p-6">
        <div className="flex items-center justify-between">
          <h2 className="font-display text-lg font-bold text-ink-900">Recent activity</h2>
          <Link href="/activity" className="text-sm font-medium text-jade-600 hover:text-jade-700">
            View all
          </Link>
        </div>
        <ul className="mt-4 divide-y divide-ink-900/[0.06]">
          {recentActivity.length === 0 && (
            <li className="py-6 text-center text-sm text-ink-400">No activity yet.</li>
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
                  <p className="truncate text-sm font-semibold text-ink-900">{item.description}</p>
                  <p className="truncate text-xs text-ink-500">
                    {timeAgo(item.createdAt)}
                  </p>
                </div>
                {item.amountCents != null && (
                  <p
                    className={`text-sm font-semibold ${positive ? "text-jade-600" : "text-ink-900"}`}
                  >
                    {formatMoney(item.amountCents, { sign: true })}
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
