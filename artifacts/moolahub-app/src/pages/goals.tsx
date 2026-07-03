import { Link, useRoute } from "wouter";
import { Plus, Repeat, Calendar, ArrowRight, Info } from "lucide-react";
import { Card, Button, Badge, ProgressBar } from "@/components/ui";
import { PageHeader } from "@/components/app/bits";
import { useListGoals, useGetWallet, useCreateGoal, getListGoalsQueryKey } from "@workspace/api-client-react";
import { formatMoney, pct } from "@/lib/utils";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { ImageUploadField } from "@/components/app/ImageUploadField";
import { avatarSrc } from "@/lib/utils";
import {
  asFrequency,
  buildGoalPlan,
  nextContribution,
  FREQUENCY_OPTIONS,
  FREQUENCY_SHORT,
  FREQUENCY_NOUN,
  type Frequency,
} from "@/lib/contribution-plan";
import { useState, useMemo } from "react";
import { useQueryClient } from "@tanstack/react-query";

export default function GoalsPage() {
  const { data: goals, isLoading: goalsLoading } = useListGoals();
  const { data: wallet, isLoading: walletLoading } = useGetWallet();
  const queryClient = useQueryClient();
  const createMutation = useCreateGoal();

  const [isNewRoute] = useRoute("/goals/new");
  const [isCreateOpen, setIsCreateOpen] = useState(!!isNewRoute);
  const [name, setName] = useState("");
  const [target, setTarget] = useState("");
  const [deadline, setDeadline] = useState("");
  const [frequency, setFrequency] = useState<Frequency>("weekly");
  const [imageUrl, setImageUrl] = useState<string | null>(null);

  const previewPlan = useMemo(() => {
    const targetCents = Math.floor(parseFloat(target) * 100);
    if (!Number.isFinite(targetCents) || targetCents <= 0 || !deadline) return null;
    const deadlineDate = new Date(deadline);
    if (Number.isNaN(deadlineDate.getTime()) || deadlineDate <= new Date()) return null;
    return buildGoalPlan(targetCents, new Date(), deadlineDate, frequency);
  }, [target, deadline, frequency]);

  const handleCreate = (e: React.FormEvent) => {
    e.preventDefault();
    createMutation.mutate(
      { 
        data: { 
          name, 
          targetCents: Math.floor(parseFloat(target) * 100), 
          deadline: new Date(deadline).toISOString(),
          frequency,
          imageUrl: imageUrl ?? undefined,
        } 
      },
      {
        onSuccess: () => {
          queryClient.invalidateQueries({ queryKey: getListGoalsQueryKey() });
          setIsCreateOpen(false);
          setName("");
          setTarget("");
          setDeadline("");
          setFrequency("weekly");
          setImageUrl(null);
        }
      }
    );
  };

  if (goalsLoading || walletLoading) {
    return <div className="p-8 text-center text-muted-foreground">Loading your personal savings…</div>;
  }

  const goalsList = goals ?? [];
  const totalTarget = goalsList.reduce((s, g) => s + g.targetCents, 0);
  const totalSaved = goalsList.reduce((s, g) => s + g.savedCents, 0);

  return (
    <div className="mx-auto max-w-6xl space-y-6">
      <PageHeader
        eyebrow="Personal Savings"
        title="Your personal savings"
        description="Set a target and a date, and we'll track your progress. Each goal is a pot within your one wallet, not a separate account."
        action={
          <Dialog open={isCreateOpen} onOpenChange={setIsCreateOpen}>
            <DialogTrigger asChild>
              <Button>
                <Plus className="h-4 w-4" /> New goal
              </Button>
            </DialogTrigger>
            <DialogContent>
              <DialogHeader>
                <DialogTitle>Create a goal</DialogTitle>
              </DialogHeader>
              <form onSubmit={handleCreate} className="space-y-4 pt-4">
                <div className="space-y-2">
                  <Label>Goal name</Label>
                  <Input value={name} onChange={e => setName(e.target.value)} required placeholder="e.g. Emergency fund" />
                </div>
                <div className="space-y-2">
                  <Label>Target amount (USDC)</Label>
                  <Input type="number" value={target} onChange={e => setTarget(e.target.value)} required placeholder="1000" />
                </div>
                <div className="space-y-2">
                  <Label>Target date</Label>
                  <Input type="date" value={deadline} onChange={e => setDeadline(e.target.value)} required />
                </div>
                <div className="space-y-2">
                  <Label>Contribution frequency</Label>
                  <Select value={frequency} onValueChange={(v) => setFrequency(asFrequency(v))}>
                    <SelectTrigger><SelectValue /></SelectTrigger>
                    <SelectContent>
                      {FREQUENCY_OPTIONS.map((o) => (
                        <SelectItem key={o.value} value={o.value}>{o.label}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <p className="text-xs text-muted-foreground">
                    Contributions start small to build the habit and grow gradually until you hit your target.
                  </p>
                </div>
                {previewPlan && (
                  <div className="rounded-xl border border-jade-500/15 bg-jade-50/50 p-4 dark:bg-jade-500/15">
                    <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-jade-700 dark:text-jade-300">
                      Your savings plan
                    </p>
                    <p className="mt-1.5 text-sm text-foreground">
                      Start at{" "}
                      <span className="font-semibold text-foreground">
                        {formatMoney(previewPlan.firstCents)}
                      </span>{" "}
                      this {FREQUENCY_NOUN[frequency]} and build up to{" "}
                      <span className="font-semibold text-foreground">
                        {formatMoney(previewPlan.lastCents)}
                      </span>{" "}
                      over {previewPlan.periods}{" "}
                      {FREQUENCY_NOUN[frequency]}
                      {previewPlan.periods === 1 ? "" : "s"}.
                    </p>
                  </div>
                )}
                <ImageUploadField
                  label="Picture (optional)"
                  hint="Add a photo of what you're saving for to keep the dream alive."
                  value={imageUrl}
                  onChange={setImageUrl}
                />
                <Button type="submit" className="w-full" disabled={createMutation.isPending}>
                  {createMutation.isPending ? "Creating…" : "Create Goal"}
                </Button>
              </form>
            </DialogContent>
          </Dialog>
        }
      />

      <div className="grid gap-4 sm:grid-cols-3">
        <Card className="p-5">
          <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-muted-foreground">
            Allocated to savings
          </p>
          <p className="mt-1 font-display text-2xl font-bold text-foreground">
            {formatMoney(totalSaved)}
          </p>
        </Card>
        <Card className="p-5">
          <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-muted-foreground">
            Combined target
          </p>
          <p className="mt-1 font-display text-2xl font-bold text-foreground">
            {formatMoney(totalTarget)}
          </p>
        </Card>
        <Card className="p-5">
          <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-muted-foreground">
            Overall progress
          </p>
          <p className="mt-1 font-display text-2xl font-bold text-jade-600 dark:text-jade-400">
            {pct(totalSaved, totalTarget)}%
          </p>
        </Card>
      </div>

      <div className="grid gap-5 md:grid-cols-2 lg:grid-cols-3">
        {goalsList.map((g) => {
          const gFreq = asFrequency(g.frequency);
          const gPlan = buildGoalPlan(g.targetCents, g.createdAt, g.deadline, gFreq);
          const gNext = nextContribution(gPlan.plan, g.savedCents);
          return (
          <Link key={g.id} href={`/goals/${g.id}`} className="group block">
            <Card className="h-full overflow-hidden p-0 transition-[border-color,background-color] duration-150 group-hover:border-jade-500/25">
              {g.imageUrl && (
                <div className="h-32 w-full overflow-hidden bg-background">
                  <img
                    src={avatarSrc(g.imageUrl)}
                    alt=""
                    className="h-full w-full object-cover transition-transform duration-200 group-hover:scale-[1.03]"
                  />
                </div>
              )}
              <div className="p-6">
              <div className="flex items-start justify-between">
                <span className="flex h-12 w-12 items-center justify-center rounded-2xl bg-background text-2xl">
                  {g.emoji || "🎯"}
                </span>
                {gNext && (
                  <Badge tone="jade">
                    <Repeat className="h-3 w-3" /> next {formatMoney(gNext.amountCents, { compact: true })}/{FREQUENCY_SHORT[gFreq]}
                  </Badge>
                )}
              </div>
              <h3 className="mt-4 font-display text-lg font-bold text-foreground">{g.name}</h3>
              <div className="mt-1 flex items-center gap-1.5 text-xs text-muted-foreground">
                <Calendar className="h-3.5 w-3.5" />
                by{" "}
                {new Date(g.deadline).toLocaleDateString("en-US", { month: "long", day: "numeric" })}
              </div>

              <div className="mt-5">
                <div className="flex items-end justify-between">
                  <p className="font-display text-xl font-bold text-foreground">
                    {formatMoney(g.savedCents)}
                  </p>
                  <p className="text-sm text-muted-foreground">of {formatMoney(g.targetCents)}</p>
                </div>
                <ProgressBar value={g.savedCents} total={g.targetCents} className="mt-2" />
                <p className="mt-2 text-xs font-medium text-jade-600 dark:text-jade-400">
                  {pct(g.savedCents, g.targetCents)}% there
                </p>
              </div>

              <div className="mt-4 inline-flex items-center gap-1.5 text-sm font-medium text-jade-600 dark:text-jade-400">
                Manage goal{" "}
                <ArrowRight className="h-4 w-4 transition-transform group-hover:translate-x-0.5" />
              </div>
              </div>
            </Card>
          </Link>
          );
        })}

        <button
          onClick={() => setIsCreateOpen(true)}
          className="flex min-h-[280px] flex-col items-center justify-center gap-3 rounded-2xl border-2 border-dashed border-border p-6 text-muted-foreground transition-[color,border-color,transform] duration-150 hover:border-jade-500/35 hover:text-jade-600 dark:hover:text-jade-400 active:scale-[0.99] focus-ring"
        >
          <span className="flex h-12 w-12 items-center justify-center rounded-xl border border-border bg-card">
            <Plus className="h-6 w-6" />
          </span>
          <span className="text-sm font-semibold">Create a goal</span>
        </button>
      </div>

      <Card className="flex items-start gap-3 border-sky-500/15 bg-sky-50/50 p-5 dark:bg-sky-500/15">
        <Info className="mt-0.5 h-5 w-5 shrink-0 text-sky-600 dark:text-sky-400" />
        <p className="text-sm text-muted-foreground">
          You currently have{" "}
          <span className="font-semibold text-foreground">
            {formatMoney(wallet?.availableCents ?? 0)}
          </span>{" "}
          unallocated. Assign it to a goal to keep your saving on track.
        </p>
      </Card>
    </div>
  );
}
