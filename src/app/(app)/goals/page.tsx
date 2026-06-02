import Link from "next/link";
import { Plus, Repeat, Calendar, ArrowRight, Info } from "lucide-react";
import { Card, Button, Badge, ProgressBar } from "@/components/ui";
import { PageHeader } from "@/components/app/bits";
import { requireUser } from "@/lib/server/auth";
import { listGoals } from "@/lib/server/goals";
import { userBalances } from "@/lib/server/ledger";
import { formatMoney, pct } from "@/lib/utils";

export default async function GoalsPage() {
  const user = await requireUser();
  const [goals, balances] = await Promise.all([listGoals(user.id), userBalances(user.id)]);

  const totalTarget = goals.reduce((s, g) => s + g.targetCents, 0);
  const totalSaved = goals.reduce((s, g) => s + g.savedCents, 0);

  return (
    <div className="mx-auto max-w-6xl space-y-6">
      <PageHeader
        eyebrow="Savings Goals"
        title="Your goals"
        description="Name a target, automate a weekly amount, and climb toward it. Goals are allocations over your one wallet — not separate accounts."
        action={
          <Button href="/goals/new">
            <Plus className="h-4 w-4" /> New goal
          </Button>
        }
      />

      <div className="grid gap-4 sm:grid-cols-3">
        <Card className="p-5">
          <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-ink-400">
            Allocated to goals
          </p>
          <p className="mt-1 font-display text-2xl font-bold text-ink-900">
            {formatMoney(totalSaved)}
          </p>
        </Card>
        <Card className="p-5">
          <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-ink-400">
            Combined target
          </p>
          <p className="mt-1 font-display text-2xl font-bold text-ink-900">
            {formatMoney(totalTarget)}
          </p>
        </Card>
        <Card className="p-5">
          <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-ink-400">
            Overall progress
          </p>
          <p className="mt-1 font-display text-2xl font-bold text-jade-600">
            {pct(totalSaved, totalTarget)}%
          </p>
        </Card>
      </div>

      <div className="grid gap-5 md:grid-cols-2 lg:grid-cols-3">
        {goals.map((g) => (
          <Link key={g.id} href={`/goals/${g.id}`} className="group">
            <Card className="h-full p-6 transition-all group-hover:-translate-y-1 group-hover:shadow-card-hover">
              <div className="flex items-start justify-between">
                <span className="flex h-12 w-12 items-center justify-center rounded-2xl bg-mist text-2xl">
                  {g.emoji}
                </span>
                {g.autoSaveCents && (
                  <Badge tone="jade">
                    <Repeat className="h-3 w-3" /> {formatMoney(g.autoSaveCents, { compact: true })}/wk
                  </Badge>
                )}
              </div>
              <h3 className="mt-4 font-display text-lg font-bold text-ink-900">{g.name}</h3>
              <div className="mt-1 flex items-center gap-1.5 text-xs text-ink-500">
                <Calendar className="h-3.5 w-3.5" />
                by{" "}
                {g.deadline.toLocaleDateString("en-US", { month: "long", day: "numeric" })}
              </div>

              <div className="mt-5">
                <div className="flex items-end justify-between">
                  <p className="font-display text-xl font-bold text-ink-900">
                    {formatMoney(g.savedCents)}
                  </p>
                  <p className="text-sm text-ink-400">of {formatMoney(g.targetCents)}</p>
                </div>
                <ProgressBar value={g.savedCents} total={g.targetCents} className="mt-2" />
                <p className="mt-2 text-xs font-medium text-jade-600">
                  {pct(g.savedCents, g.targetCents)}% there
                </p>
              </div>

              <div className="mt-4 inline-flex items-center gap-1.5 text-sm font-medium text-jade-600">
                Manage goal{" "}
                <ArrowRight className="h-4 w-4 transition-transform group-hover:translate-x-0.5" />
              </div>
            </Card>
          </Link>
        ))}

        <Link
          href="/goals/new"
          className="flex min-h-[280px] flex-col items-center justify-center gap-3 rounded-3xl border-2 border-dashed border-ink-900/15 p-6 text-ink-400 transition-colors hover:border-jade-500/40 hover:text-jade-600 focus-ring"
        >
          <span className="flex h-12 w-12 items-center justify-center rounded-2xl bg-white shadow-card">
            <Plus className="h-6 w-6" />
          </span>
          <span className="text-sm font-semibold">Create a goal</span>
        </Link>
      </div>

      <Card className="flex items-start gap-3 border-sky-500/15 bg-sky-50/50 p-5">
        <Info className="mt-0.5 h-5 w-5 shrink-0 text-sky-600" />
        <p className="text-sm text-ink-600">
          You currently have{" "}
          <span className="font-semibold text-ink-900">
            {formatMoney(balances.availableCents)}
          </span>{" "}
          unallocated. Assign it to a goal to keep your saving on track — or opt in to yield so
          idle balances can grow while you wait.
        </p>
      </Card>
    </div>
  );
}
