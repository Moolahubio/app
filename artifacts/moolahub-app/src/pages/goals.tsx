import { Link, useRoute } from "wouter";
import { Plus, Repeat, Calendar, ArrowRight, Info } from "lucide-react";
import { Card, Button, Badge, ProgressBar } from "@/components/ui";
import { PageHeader } from "@/components/app/bits";
import { useListGoals, useGetWallet, useCreateGoal, getListGoalsQueryKey } from "@workspace/api-client-react";
import { formatMoney, pct } from "@/lib/utils";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { ImageUploadField } from "@/components/app/ImageUploadField";
import { avatarSrc } from "@/lib/utils";
import { useState } from "react";
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
  const [imageUrl, setImageUrl] = useState<string | null>(null);

  const handleCreate = (e: React.FormEvent) => {
    e.preventDefault();
    createMutation.mutate(
      { 
        data: { 
          name, 
          targetCents: Math.floor(parseFloat(target) * 100), 
          deadline: new Date(deadline).toISOString(),
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
          setImageUrl(null);
        }
      }
    );
  };

  if (goalsLoading || walletLoading) {
    return <div className="p-8 text-center text-ink-400">Loading goals...</div>;
  }

  const goalsList = goals ?? [];
  const totalTarget = goalsList.reduce((s, g) => s + g.targetCents, 0);
  const totalSaved = goalsList.reduce((s, g) => s + g.savedCents, 0);

  return (
    <div className="mx-auto max-w-6xl space-y-6">
      <PageHeader
        eyebrow="Savings Goals"
        title="Your goals"
        description="Name a target, automate a weekly amount, and climb toward it. Goals are allocations over your one wallet — not separate accounts."
        action={
          <Dialog open={isCreateOpen} onOpenChange={setIsCreateOpen}>
            <DialogTrigger asChild>
              <Button>
                <Plus className="h-4 w-4" /> New goal
              </Button>
            </DialogTrigger>
            <DialogContent>
              <DialogHeader>
                <DialogTitle>Create a savings goal</DialogTitle>
              </DialogHeader>
              <form onSubmit={handleCreate} className="space-y-4 pt-4">
                <div className="space-y-2">
                  <Label>Goal Name</Label>
                  <Input value={name} onChange={e => setName(e.target.value)} required placeholder="Emergency Fund" />
                </div>
                <div className="space-y-2">
                  <Label>Target Amount (USDC)</Label>
                  <Input type="number" value={target} onChange={e => setTarget(e.target.value)} required placeholder="1000" />
                </div>
                <div className="space-y-2">
                  <Label>Target Date</Label>
                  <Input type="date" value={deadline} onChange={e => setDeadline(e.target.value)} required />
                </div>
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
        {goalsList.map((g) => (
          <Link key={g.id} href={`/goals/${g.id}`} className="group block">
            <Card className="h-full overflow-hidden p-0 transition-[border-color,background-color] duration-150 group-hover:border-jade-500/25">
              {g.imageUrl && (
                <div className="h-32 w-full overflow-hidden bg-mist">
                  <img
                    src={avatarSrc(g.imageUrl)}
                    alt=""
                    className="h-full w-full object-cover transition-transform duration-200 group-hover:scale-[1.03]"
                  />
                </div>
              )}
              <div className="p-6">
              <div className="flex items-start justify-between">
                <span className="flex h-12 w-12 items-center justify-center rounded-2xl bg-mist text-2xl">
                  {g.emoji || "🎯"}
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
                {new Date(g.deadline).toLocaleDateString("en-US", { month: "long", day: "numeric" })}
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
              </div>
            </Card>
          </Link>
        ))}

        <button
          onClick={() => setIsCreateOpen(true)}
          className="flex min-h-[280px] flex-col items-center justify-center gap-3 rounded-2xl border-2 border-dashed border-ink-900/12 p-6 text-ink-400 transition-[color,border-color,transform] duration-150 hover:border-jade-500/35 hover:text-jade-600 active:scale-[0.99] focus-ring"
        >
          <span className="flex h-12 w-12 items-center justify-center rounded-xl border border-ink-900/8 bg-white">
            <Plus className="h-6 w-6" />
          </span>
          <span className="text-sm font-semibold">Create a goal</span>
        </button>
      </div>

      <Card className="flex items-start gap-3 border-sky-500/15 bg-sky-50/50 p-5">
        <Info className="mt-0.5 h-5 w-5 shrink-0 text-sky-600" />
        <p className="text-sm text-ink-600">
          You currently have{" "}
          <span className="font-semibold text-ink-900">
            {formatMoney(wallet?.availableCents ?? 0)}
          </span>{" "}
          unallocated. Assign it to a goal to keep your saving on track — or opt in to yield so
          idle balances can grow while you wait.
        </p>
      </Card>
    </div>
  );
}
