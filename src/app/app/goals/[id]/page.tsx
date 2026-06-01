import { notFound } from "next/navigation";
import { Plus, Repeat, Calendar, Target, Sparkles, Minus } from "lucide-react";
import { Card, Button, Badge } from "@/components/ui";
import { BackLink } from "@/components/app/bits";
import { goals } from "@/lib/data";
import { formatMoney, pct } from "@/lib/utils";

export function generateStaticParams() {
  return goals.map((g) => ({ id: g.id }));
}

export default async function GoalDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const goal = goals.find((g) => g.id === id);
  if (!goal) notFound();

  const remaining = goal.targetCents - goal.savedCents;
  const progress = pct(goal.savedCents, goal.targetCents);
  const weeksLeft = goal.autoSaveCents
    ? Math.ceil(remaining / goal.autoSaveCents)
    : null;
  const circumference = 2 * Math.PI * 52;

  return (
    <div className="mx-auto max-w-4xl space-y-6">
      <BackLink href="/app/goals" label="All goals" />

      <div className="grid gap-6 md:grid-cols-5">
        {/* progress ring */}
        <Card className="flex flex-col items-center justify-center p-8 text-center md:col-span-2">
          <span className="mb-4 flex h-14 w-14 items-center justify-center rounded-2xl bg-mist text-3xl">
            {goal.emoji}
          </span>
          <div className="relative h-40 w-40">
            <svg viewBox="0 0 120 120" className="h-full w-full -rotate-90">
              <circle cx="60" cy="60" r="52" fill="none" stroke="#0C151212" strokeWidth="12" />
              <circle
                cx="60"
                cy="60"
                r="52"
                fill="none"
                stroke="#0E9E6E"
                strokeWidth="12"
                strokeLinecap="round"
                strokeDasharray={circumference}
                strokeDashoffset={circumference - (progress / 100) * circumference}
              />
            </svg>
            <div className="absolute inset-0 flex flex-col items-center justify-center">
              <span className="font-display text-3xl font-bold text-ink-900">{progress}%</span>
              <span className="font-mono text-[10px] uppercase tracking-wide text-ink-400">
                saved
              </span>
            </div>
          </div>
          <h1 className="mt-5 font-display text-xl font-bold text-ink-900">{goal.name}</h1>
          <p className="text-sm text-ink-500">
            {formatMoney(goal.savedCents)} of {formatMoney(goal.targetCents)}
          </p>
        </Card>

        {/* details + actions */}
        <div className="space-y-6 md:col-span-3">
          <Card className="p-6">
            <h2 className="font-display text-lg font-bold text-ink-900">Add to this goal</h2>
            <p className="mt-1 text-sm text-ink-500">
              Move funds from your available balance into this allocation.
            </p>
            <div className="mt-4 flex flex-wrap gap-2">
              {[1000, 2500, 5000].map((amt) => (
                <button
                  key={amt}
                  className="rounded-full border border-ink-900/10 bg-white px-4 py-2 text-sm font-semibold text-ink-700 transition-colors hover:border-jade-500/40 hover:text-jade-700 focus-ring"
                >
                  +{formatMoney(amt, { compact: true })}
                </button>
              ))}
            </div>
            <div className="mt-4 flex gap-3">
              <Button className="flex-1">
                <Plus className="h-4 w-4" /> Add funds
              </Button>
              <Button variant="secondary">
                <Minus className="h-4 w-4" /> Withdraw
              </Button>
            </div>
          </Card>

          <div className="grid gap-4 sm:grid-cols-2">
            <Card className="p-5">
              <div className="flex items-center gap-2 text-jade-600">
                <Target className="h-4 w-4" />
                <p className="font-mono text-[10px] uppercase tracking-[0.15em]">Remaining</p>
              </div>
              <p className="mt-1.5 font-display text-xl font-bold text-ink-900">
                {formatMoney(remaining)}
              </p>
            </Card>
            <Card className="p-5">
              <div className="flex items-center gap-2 text-jade-600">
                <Calendar className="h-4 w-4" />
                <p className="font-mono text-[10px] uppercase tracking-[0.15em]">Target date</p>
              </div>
              <p className="mt-1.5 font-display text-xl font-bold text-ink-900">
                {new Date(goal.deadline).toLocaleDateString("en-US", {
                  month: "short",
                  day: "numeric",
                  year: "numeric",
                })}
              </p>
            </Card>
          </div>

          <Card className="flex items-center justify-between p-5">
            <div className="flex items-center gap-3">
              <span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-jade-50 text-jade-600">
                <Repeat className="h-5 w-5" />
              </span>
              <div>
                <p className="font-semibold text-ink-900">Auto-save</p>
                <p className="text-sm text-ink-500">
                  {goal.autoSaveCents
                    ? `${formatMoney(goal.autoSaveCents)} every week`
                    : "Not set up yet"}
                </p>
              </div>
            </div>
            {goal.autoSaveCents ? (
              <Badge tone="jade">On</Badge>
            ) : (
              <Button variant="secondary" size="sm">
                Set up
              </Button>
            )}
          </Card>

          {weeksLeft !== null && (
            <p className="flex items-center justify-center gap-2 text-sm text-ink-500">
              <Sparkles className="h-4 w-4 text-jade-500" />
              At {formatMoney(goal.autoSaveCents!)} per week, you&apos;ll reach this goal in about{" "}
              <span className="font-semibold text-ink-900">{weeksLeft} weeks</span>.
            </p>
          )}
        </div>
      </div>
    </div>
  );
}
