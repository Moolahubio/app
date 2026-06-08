import { useState } from "react";
import { Link } from "wouter";
import { useQueryClient } from "@tanstack/react-query";
import { Flame, Snowflake, Plane, Bell, Share2, Trophy, ChevronRight } from "lucide-react";
import { Card, Badge, Button, Eyebrow } from "@/components/ui";
import { Switch } from "@/components/ui/switch";
import { PageHeader, BackLink } from "@/components/app/bits";
import {
  StreakFlameHero,
  StreakChip,
  streakVisual,
  periodNoun,
} from "@/components/app/StreakFlame";
import { StreakBadges } from "@/components/app/StreakBadges";
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
    return <div className="p-8 text-center text-muted-foreground">Loading your streaks…</div>;
  }
  if (!data) return null;

  const heroCount = data.hero?.count ?? 0;
  const heroStatus = data.hero?.status ?? "broken";
  const heroCaption = data.hero
    ? `${data.hero.commitmentName ?? "Savings"} · longest run going`
    : "Make a save to light your first flame";

  const savedAmount = summary
    ? summary.goalTotalCents + summary.circlePotCents
    : null;

  const vacation = data.vacation;

  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <BackLink href="/" label="Home" />
      <PageHeader eyebrow="Streaks" title="Savings streaks" />

      {/* Hero */}
      <Card className="p-8">
        <StreakFlameHero count={heroCount} status={heroStatus} caption={heroCaption} />
        <div className="mt-6 grid grid-cols-3 gap-3 border-t border-border pt-6 text-center">
          <Stat label="Lifetime best" value={String(data.lifetimeBest)} />
          <Stat label="Periods saved" value={String(data.totalPeriodsSaved)} />
          <Stat label="Freezes" value={String(data.freezes.balance)} />
        </div>
        <div className="mt-6 flex justify-center">
          <Button variant="secondary" onClick={() => setShareOpen(true)} disabled={heroCount === 0}>
            <Share2 className="h-4 w-4" /> Share your streak
          </Button>
        </div>
      </Card>

      {/* Per-commitment streaks */}
      <section>
        <Eyebrow className="mb-3">Your commitments</Eyebrow>
        {data.commitments.length === 0 ? (
          <Card className="p-6 text-center text-sm text-muted-foreground">
            No streaks yet. Add to a{" "}
            <Link href="/goals" className="font-semibold text-jade-600 dark:text-jade-400">
              goal
            </Link>{" "}
            or contribute to a{" "}
            <Link href="/circles" className="font-semibold text-jade-600 dark:text-jade-400">
              circle
            </Link>{" "}
            to start one.
          </Card>
        ) : (
          <div className="space-y-3">
            {data.commitments.map((c) => {
              const v = streakVisual(c.status, c.currentCount);
              const href = c.commitmentType === "goal" ? `/goals/${c.commitmentId}` : `/circles/${c.commitmentId}`;
              return (
                <Link key={c.id} href={href}>
                  <Card className="flex items-center justify-between p-4 transition-colors hover:bg-accent">
                    <div className="flex items-center gap-3">
                      <span className={`flex h-10 w-10 items-center justify-center rounded-2xl ${v.glow}`}>
                        {c.emoji ? (
                          <span className="text-xl">{c.emoji}</span>
                        ) : (
                          <v.Icon className={`h-5 w-5 ${v.color}`} />
                        )}
                      </span>
                      <div>
                        <p className="font-semibold text-foreground">{c.commitmentName}</p>
                        <p className="text-xs capitalize text-muted-foreground">
                          {c.currentPeriodSatisfied ? "Saved this " : "Open · per "}
                          {periodNoun(c.frequency)}
                          {" · best "}
                          {c.bestCount}
                        </p>
                      </div>
                    </div>
                    <div className="flex items-center gap-3">
                      <StreakChip count={c.currentCount} status={c.status} />
                      <ChevronRight className="h-5 w-5 text-muted-foreground" />
                    </div>
                  </Card>
                </Link>
              );
            })}
          </div>
        )}
      </section>

      {/* Badges */}
      <Card className="p-6">
        <div className="mb-4 flex items-center gap-2">
          <Trophy className="h-5 w-5 text-amber-500" />
          <h2 className="font-display text-lg font-bold text-foreground">Badge collection</h2>
        </div>
        <StreakBadges badges={data.badges} />
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
          <span className="ml-2 text-sm text-muted-foreground">
            {data.freezes.balance} available
          </span>
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
                A single nudge before a period closes, only if you want it. Off by default.
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
          Life happens. Pause your streaks once a year (up to 30 days) without losing your progress.
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
