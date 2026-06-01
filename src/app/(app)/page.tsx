import Link from "next/link";
import {
  Plus,
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
import { Card, Button, Badge, ProgressBar, IconChip, Eyebrow } from "@/components/ui";
import { AscendingChart } from "@/components/marketing/AscendingChart";
import {
  wallet,
  goals,
  circles,
  activity,
  reminders,
  lessons,
  currentUser,
} from "@/lib/data";
import { formatMoney, pct, timeAgo } from "@/lib/utils";

const activityIcon = {
  deposit: ArrowDownLeft,
  payout: ArrowDownLeft,
  yield: Sparkles,
  contribution: ArrowUpRight,
  goal: Target,
  withdrawal: ArrowUpRight,
} as const;

export default function DashboardPage() {
  const firstName = currentUser.name.split(" ")[0];
  const availableCents = wallet.balanceCents - wallet.allocatedCents;
  const activeCircle = circles.find((c) => c.status === "active")!;
  const nextLesson = lessons.find((l) => !l.completed)!;

  return (
    <div className="mx-auto max-w-6xl space-y-6">
      <div>
        <Eyebrow>Welcome back</Eyebrow>
        <h1 className="mt-1.5 font-display text-3xl font-bold tracking-tight text-ink-900">
          Good to see you, {firstName} 👋
        </h1>
      </div>

      <div className="grid gap-6 lg:grid-cols-3">
        {/* ---------------------------------------------- Balance hero card */}
        <Card className="relative isolate overflow-hidden border-0 bg-ink-950 p-6 text-white lg:col-span-2 lg:p-8">
          <div className="absolute inset-0 -z-10 bg-grid-dark [background-size:32px_32px] [mask-image:radial-gradient(80%_80%_at_80%_0%,black,transparent)]" />
          <div className="absolute -right-10 -top-16 -z-10 h-64 w-64 rounded-full bg-jade-500/20 blur-[90px]" />

          <div className="flex flex-wrap items-start justify-between gap-4">
            <div>
              <p className="font-mono text-[10px] uppercase tracking-[0.2em] text-white/45">
                Total balance
              </p>
              <p className="mt-1.5 font-display text-4xl font-bold sm:text-5xl">
                {formatMoney(wallet.balanceCents)}
              </p>
              <div className="mt-3 flex flex-wrap gap-x-5 gap-y-1 text-sm text-white/55">
                <span>
                  Available{" "}
                  <span className="font-semibold text-white">{formatMoney(availableCents)}</span>
                </span>
                <span>
                  In goals{" "}
                  <span className="font-semibold text-white">
                    {formatMoney(wallet.allocatedCents)}
                  </span>
                </span>
              </div>
            </div>
            <Badge tone="jade" className="bg-jade-500/15 text-jade-300 ring-jade-400/20">
              <TrendingUp className="h-3.5 w-3.5" /> +{(wallet.yieldApy * 100).toFixed(1)}% APY
            </Badge>
          </div>

          <div className="mt-6 flex flex-wrap gap-3">
            <Button size="sm">
              <Plus className="h-4 w-4" /> Add money
            </Button>
            <Button size="sm" variant="secondary" className="bg-white/10 text-white border-white/15 hover:bg-white/15">
              <ArrowUpRight className="h-4 w-4" /> Send
            </Button>
            <Button size="sm" variant="secondary" className="bg-white/10 text-white border-white/15 hover:bg-white/15">
              Withdraw
            </Button>
          </div>

          <div className="mt-6 rounded-2xl border border-white/10 bg-white/[0.03] p-4">
            <div className="flex items-center justify-between text-xs text-white/50">
              <span className="font-mono uppercase tracking-[0.15em]">Growth · 6 months</span>
              <span className="text-jade-400">+{formatMoney(wallet.yieldEarnedCents, { sign: true })} earned</span>
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
            {reminders.map((r) => (
              <li
                key={r.id}
                className="flex items-center justify-between rounded-2xl border border-ink-900/[0.06] bg-mist px-4 py-3"
              >
                <div className="min-w-0">
                  <p className="truncate text-sm font-semibold text-ink-900">{r.title}</p>
                  <p className="truncate text-xs text-ink-500">{r.detail}</p>
                </div>
                <div className="text-right">
                  <p className="text-sm font-semibold text-ink-900">
                    {formatMoney(r.amountCents, { compact: true })}
                  </p>
                  <p className="font-mono text-[10px] uppercase tracking-wide text-jade-600">
                    {new Date(r.dueDate).toLocaleDateString("en-US", { month: "short", day: "numeric" })}
                  </p>
                </div>
              </li>
            ))}
          </ul>
        </Card>
      </div>

      {/* ----------------------------------------- Goals + Circle + Learn */}
      <div className="grid gap-6 lg:grid-cols-3">
        {/* goals */}
        <Card className="p-6">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-3">
              <IconChip tone="jade"><Target className="h-5 w-5" /></IconChip>
              <h2 className="font-display text-lg font-bold text-ink-900">Your goals</h2>
            </div>
            <Link href="/goals" className="text-ink-300 transition-colors hover:text-ink-600">
              <ChevronRight className="h-5 w-5" />
            </Link>
          </div>
          <div className="mt-5 space-y-4">
            {goals.map((g) => (
              <Link key={g.id} href={`/goals/${g.id}`} className="block">
                <div className="flex items-center justify-between text-sm">
                  <span className="font-medium text-ink-800">
                    {g.emoji} {g.name}
                  </span>
                  <span className="text-ink-400">{pct(g.savedCents, g.targetCents)}%</span>
                </div>
                <ProgressBar value={g.savedCents} total={g.targetCents} className="mt-2" />
              </Link>
            ))}
          </div>
        </Card>

        {/* active circle */}
        <Card className="p-6">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-3">
              <IconChip tone="jade"><Users className="h-5 w-5" /></IconChip>
              <h2 className="font-display text-lg font-bold text-ink-900">Active circle</h2>
            </div>
            <Link href="/circles" className="text-ink-300 transition-colors hover:text-ink-600">
              <ChevronRight className="h-5 w-5" />
            </Link>
          </div>
          <Link href={`/circles/${activeCircle.id}`} className="mt-5 block">
            <p className="font-semibold text-ink-900">{activeCircle.name}</p>
            <p className="text-sm text-ink-500">
              Round {activeCircle.currentRound} of {activeCircle.totalRounds} · {activeCircle.frequency}
            </p>
            <div className="mt-4 flex items-center justify-between rounded-2xl bg-mist px-4 py-3">
              <div>
                <p className="font-mono text-[10px] uppercase tracking-wide text-ink-400">Pot</p>
                <p className="font-semibold text-ink-900">{formatMoney(activeCircle.potCents)}</p>
              </div>
              <Badge tone="jade">Your turn · Jun 5</Badge>
            </div>
          </Link>
        </Card>

        {/* continue learning */}
        <Card className="flex flex-col p-6">
          <div className="flex items-center gap-3">
            <IconChip tone="amber"><GraduationCap className="h-5 w-5" /></IconChip>
            <h2 className="font-display text-lg font-bold text-ink-900">Keep learning</h2>
          </div>
          <div className="mt-5 flex-1">
            <span className="text-3xl">{nextLesson.emoji}</span>
            <p className="mt-3 font-semibold leading-snug text-ink-900">{nextLesson.title}</p>
            <p className="mt-1 font-mono text-xs uppercase tracking-wide text-ink-400">
              {nextLesson.minutes} min · {nextLesson.level}
            </p>
          </div>
          <Button href={`/learn/${nextLesson.slug}`} variant="secondary" size="sm" className="mt-5 w-full">
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
          {activity.slice(0, 5).map((item) => {
            const Icon = activityIcon[item.type];
            const positive = item.amountCents > 0;
            return (
              <li key={item.id} className="flex items-center gap-4 py-3">
                <IconChip tone={positive ? "jade" : "ink"} className="h-10 w-10">
                  <Icon className="h-5 w-5" />
                </IconChip>
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-semibold text-ink-900">{item.title}</p>
                  <p className="truncate text-xs text-ink-500">
                    {item.subtitle} · {timeAgo(item.date)}
                  </p>
                </div>
                <p className={`text-sm font-semibold ${positive ? "text-jade-600" : "text-ink-900"}`}>
                  {formatMoney(item.amountCents, { sign: true })}
                </p>
              </li>
            );
          })}
        </ul>
      </Card>
    </div>
  );
}
