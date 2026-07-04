import { useState } from "react";
import { Link } from "wouter";
import { useQueryClient } from "@tanstack/react-query";
import {
  Snowflake,
  Plane,
  Bell,
  Share2,
  Trophy,
  Target,
  Users,
  Settings2,
  ShieldCheck,
} from "lucide-react";
import { Card, Badge, Button } from "@/components/ui";
import { Switch } from "@/components/ui/switch";
import { PageHeader, BackLink } from "@/components/app/bits";
import { StreakFlameHero, periodNoun, streakUnit } from "@/components/app/StreakFlame";
import { StreakBadges, StreakBadgeTier } from "@/components/app/StreakBadges";
import { StreakShareCard } from "@/components/app/StreakShareCard";
import { useStreak, getGetStreaksQueryKey } from "@/hooks/use-streak";
import {
  useSetStreakReminders,
  useStartStreakVacation,
  useEndStreakVacation,
  useGetDashboardSummary,
} from "@workspace/api-client-react";
import { apiErrorMessage } from "@/lib/utils";

const VACATION_DAYS = 14;

export default function StreaksPage() {
  const { data, isLoading } = useStreak();
  const { data: summary } = useGetDashboardSummary();
  const queryClient = useQueryClient();

  const setReminders = useSetStreakReminders();
  const startVacation = useStartStreakVacation();
  const endVacation = useEndStreakVacation();

  const [shareOpen, setShareOpen] = useState(false);

  const refresh = () => queryClient.invalidateQueries({ queryKey: getGetStreaksQueryKey() });

  if (isLoading) {
    return <div className="p-8 text-center text-muted-foreground">Loading your streak…</div>;
  }
  if (!data) return null;

  const heroCount = data.hero?.count ?? 0;
  const heroStatus = data.hero?.status ?? "broken";
  const unit = streakUnit(data.frequency, heroCount);
  const heroCaption = data.hero
    ? `${heroCount}-${periodNoun(data.frequency)} streak · keep it going`
    : `Make a deposit this ${periodNoun(data.frequency)} to light your flame`;

  const savedAmount = summary ? summary.goalTotalCents + summary.circlePotCents : null;
  const vacation = data.vacation;
  const periodEnd = data.currentPeriodEnd ? new Date(data.currentPeriodEnd) : null;

  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <BackLink href="/" label="Home" />
      <PageHeader eyebrow="Streaks" title="Savings streak" />

      {/* Gentle at-risk nudge — never alarming */}
      {data.atRisk && periodEnd && (
        <div className="flex items-start gap-3 rounded-2xl border border-jade-500/30 bg-jade-500/[0.06] p-4">
          <Bell className="mt-0.5 h-5 w-5 shrink-0 text-jade-600 dark:text-jade-400" />
          <p className="text-sm text-foreground">
            A single deposit before{" "}
            <span className="font-semibold">
              {periodEnd.toLocaleDateString("en-US", { weekday: "long", month: "short", day: "numeric" })}
            </span>{" "}
            keeps your streak alive. No rush, any goal or circle deposit counts.
          </p>
        </div>
      )}

      {/* Hero */}
      <Card className="p-8">
        <StreakFlameHero count={heroCount} status={heroStatus} caption={heroCaption} />
        <div className="mt-6 grid grid-cols-3 gap-3 border-t border-border pt-6 text-center">
          <Stat label={`Current ${unit}`} value={String(heroCount)} />
          <Stat label="Lifetime best" value={String(data.lifetimeBest)} />
          <Stat label="Periods saved" value={String(data.totalPeriodsSaved)} />
        </div>
        <div className="mt-6 flex justify-center">
          <Button variant="secondary" onClick={() => setShareOpen(true)} disabled={heroCount === 0}>
            <Share2 className="h-4 w-4" /> Share your streak
          </Button>
        </div>
      </Card>

      {/* Frequency + where saves count */}
      <Card className="p-6">
        <div className="flex items-center justify-between gap-4">
          <div>
            <p className="font-semibold capitalize text-foreground">{data.frequency} streak</p>
            <p className="mt-0.5 text-sm text-muted-foreground">
              One deposit per {periodNoun(data.frequency)} keeps your flame lit.
            </p>
          </div>
          <Link href="/profile/streak">
            <Button variant="secondary" size="sm">
              <Settings2 className="h-4 w-4" /> Change
            </Button>
          </Link>
        </div>
        <div className="mt-4 grid gap-3 sm:grid-cols-2">
          <div className="flex items-center gap-3 rounded-2xl border border-border bg-background px-4 py-3">
            <span className="flex h-9 w-9 items-center justify-center rounded-xl bg-jade-500/15 text-jade-600 dark:text-jade-400">
              <Target className="h-5 w-5" />
            </span>
            <p className="text-sm text-muted-foreground">Goal deposits count</p>
          </div>
          <div className="flex items-center gap-3 rounded-2xl border border-border bg-background px-4 py-3">
            <span className="flex h-9 w-9 items-center justify-center rounded-xl bg-jade-500/15 text-jade-600 dark:text-jade-400">
              <Users className="h-5 w-5" />
            </span>
            <p className="text-sm text-muted-foreground">Circle contributions count</p>
          </div>
        </div>
        {!data.canChangeFrequency && (
          <p className="mt-3 text-xs text-muted-foreground">
            Frequency can change once a year
            {data.nextChangeYear ? `. Next change unlocks in ${data.nextChangeYear}.` : "."}
          </p>
        )}
      </Card>

      {/* Badge tier + progress */}
      <Card className="p-6">
        <div className="mb-4 flex items-center gap-2">
          <Trophy className="h-5 w-5 text-amber-500" />
          <h2 className="font-display text-lg font-bold text-foreground">Badge collection</h2>
        </div>
        <StreakBadgeTier progress={data.badgeProgress} />
        <div className="mt-5">
          <StreakBadges badges={data.badges} />
        </div>
      </Card>

      {/* Freezes */}
      <Card className="p-6">
        <div className="flex items-center gap-2">
          <Snowflake className="h-5 w-5 text-sky-500" />
          <h2 className="font-display text-lg font-bold text-foreground">Streak freezes</h2>
        </div>
        <p className="mt-1 text-sm text-muted-foreground">
          A freeze automatically protects your streak if you miss a single period. You earn one every
          three months (up to four a year), and at most one can be used per quarter.
        </p>
        <div className="mt-4 flex items-center gap-2">
          {Array.from({ length: 4 }).map((_, i) => (
            <span
              key={i}
              className={`flex h-10 w-10 items-center justify-center rounded-2xl ${
                i < data.freezes.balance ? "bg-sky-500/15 text-sky-500" : "bg-muted text-muted-foreground/40"
              }`}
            >
              <Snowflake className="h-5 w-5" />
            </span>
          ))}
          <span className="ml-2 text-sm text-muted-foreground">{data.freezes.balance} available</span>
        </div>
      </Card>

      {/* Reminders */}
      <Card className="p-6">
        <div className="flex items-center justify-between gap-4">
          <div className="flex items-start gap-3">
            <Bell className="mt-0.5 h-5 w-5 text-jade-600 dark:text-jade-400" />
            <div>
              <p className="font-semibold text-foreground">Gentle reminders</p>
              <p className="text-sm text-muted-foreground">
                A single nudge before a {periodNoun(data.frequency)} closes, only if you want it. Off by
                default.
              </p>
            </div>
          </div>
          <Switch
            checked={data.reminderOptIn}
            disabled={setReminders.isPending}
            onCheckedChange={(checked) =>
              setReminders.mutate({ data: { optIn: checked } }, { onSuccess: refresh })
            }
          />
        </div>
        {setReminders.error && (
          <p className="mt-3 text-sm text-rose-600">{apiErrorMessage(setReminders.error)}</p>
        )}
      </Card>

      {/* Vacation */}
      <Card className="p-6">
        <div className="flex items-center gap-2">
          <Plane className="h-5 w-5 text-jade-600 dark:text-jade-400" />
          <h2 className="font-display text-lg font-bold text-foreground">Vacation mode</h2>
        </div>
        <p className="mt-1 text-sm text-muted-foreground">
          Life happens. Pause your streak once a year (up to 30 days) without losing your progress.
        </p>
        {vacation.active ? (
          <div className="mt-4 space-y-3">
            <Badge tone="sky">
              <Plane className="h-3.5 w-3.5" /> On vacation
              {vacation.end
                ? ` until ${new Date(vacation.end).toLocaleDateString("en-US", { month: "short", day: "numeric" })}`
                : ""}
            </Badge>
            <Button
              variant="secondary"
              onClick={() => endVacation.mutate(undefined, { onSuccess: refresh })}
              disabled={endVacation.isPending}
            >
              {endVacation.isPending ? "Ending…" : "End vacation early"}
            </Button>
          </div>
        ) : (
          <div className="mt-4">
            <Button
              onClick={() =>
                startVacation.mutate({ data: { days: VACATION_DAYS } }, { onSuccess: refresh })
              }
              disabled={startVacation.isPending || vacation.usedThisYear}
            >
              <Plane className="h-4 w-4" />
              {vacation.usedThisYear
                ? "Vacation used this year"
                : startVacation.isPending
                  ? "Starting…"
                  : `Start a ${VACATION_DAYS}-day vacation`}
            </Button>
            {startVacation.error && (
              <p className="mt-3 text-sm text-rose-600">{apiErrorMessage(startVacation.error)}</p>
            )}
          </div>
        )}
      </Card>

      <p className="flex items-center justify-center gap-1.5 text-center text-xs text-muted-foreground">
        <ShieldCheck className="h-3.5 w-3.5" /> Your streak never affects your balance or your money.
      </p>

      <StreakShareCard
        open={shareOpen}
        onOpenChange={setShareOpen}
        count={heroCount}
        caption={heroCaption}
        amountCents={savedAmount}
      />
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="font-display text-2xl font-bold tabular-nums text-foreground">{value}</p>
      <p className="mt-0.5 font-mono text-[10px] uppercase tracking-[0.15em] text-muted-foreground">
        {label}
      </p>
    </div>
  );
}
