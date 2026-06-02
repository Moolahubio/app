import { notFound } from "next/navigation";
import { Repeat, Calendar, Target, Sparkles } from "lucide-react";
import { Card, Badge } from "@/components/ui";
import { BackLink } from "@/components/app/bits";
import { AmountForm } from "@/components/app/forms";
import { requireUser } from "@/lib/server/auth";
import { getGoal } from "@/lib/server/goals";
import { allocateGoalAction, releaseGoalAction } from "@/app/(app)/actions";
import { formatMoney, pct } from "@/lib/utils";

export default async function GoalDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const user = await requireUser();
  const goal = await getGoal(user.id, id);
  if (!goal) notFound();

  const remaining = Math.max(0, goal.targetCents - goal.savedCents);
  const progress = pct(goal.savedCents, goal.targetCents);
  const weeksLeft = goal.autoSaveCents ? Math.ceil(remaining / goal.autoSaveCents) : null;
  const circumference = 2 * Math.PI * 52;

  return (
    <div className="mx-auto max-w-4xl space-y-6">
      <BackLink href="/goals" label="All goals" />

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
            <div className="mt-4">
              <AmountForm
                action={allocateGoalAction}
                hidden={{ goalId: goal.id }}
                presets={[1000, 2500, 5000]}
                submitLabel="Add funds"
              />
            </div>
            <div className="mt-5 border-t border-ink-900/[0.06] pt-5">
              <p className="mb-3 text-sm font-medium text-ink-700">Withdraw from this goal</p>
              <AmountForm
                action={releaseGoalAction}
                hidden={{ goalId: goal.id }}
                submitLabel="Withdraw to available"
                variant="secondary"
              />
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
                {goal.deadline.toLocaleDateString("en-US", {
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
            {goal.autoSaveCents ? <Badge tone="jade">On</Badge> : <Badge tone="neutral">Off</Badge>}
          </Card>

          {weeksLeft !== null && remaining > 0 && (
            <p className="flex items-center justify-center gap-2 text-center text-sm text-ink-500">
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
