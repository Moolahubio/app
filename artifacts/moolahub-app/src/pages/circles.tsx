import { Link } from "wouter";
import { Plus, Users, ArrowRight, ShieldCheck, Inbox } from "lucide-react";
import { Card, Button, Badge, ProgressBar, Avatar, Eyebrow, Skeleton } from "@/components/ui";
import { PageHeader } from "@/components/app/bits";
import { ActionButton } from "@/components/app/forms";
import { useListCircles, useListInvites, useAcceptInvite, useDeclineInvite, useCreateCircle, getListCirclesQueryKey, getListInvitesQueryKey } from "@workspace/api-client-react";
import { formatMoney } from "@/lib/utils";
import { useQueryClient } from "@tanstack/react-query";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { ImageUploadField } from "@/components/app/ImageUploadField";
import { avatarSrc } from "@/lib/utils";
import { useState } from "react";

const statusTone = {
  active: "jade",
  forming: "amber",
  completed: "neutral",
} as const;

export default function CirclesPage() {
  const { data: circles, isLoading: circlesLoading } = useListCircles();
  const { data: invites, isLoading: invitesLoading } = useListInvites();
  
  const queryClient = useQueryClient();
  const acceptMutation = useAcceptInvite();
  const declineMutation = useDeclineInvite();
  const createMutation = useCreateCircle();

  const [isCreateOpen, setIsCreateOpen] = useState(false);
  const [name, setName] = useState("");
  const [contribution, setContribution] = useState("");
  const [frequency, setFrequency] = useState("weekly");
  const [emails, setEmails] = useState("");
  const [imageUrl, setImageUrl] = useState<string | null>(null);

  const handleCreate = (e: React.FormEvent) => {
    e.preventDefault();
    createMutation.mutate(
      { 
        data: { 
          name, 
          contributionCents: Math.floor(parseFloat(contribution) * 100), 
          frequency, 
          memberEmails: emails.split(",").map(e => e.trim()).filter(Boolean),
          imageUrl: imageUrl ?? undefined,
        } 
      },
      {
        onSuccess: () => {
          queryClient.invalidateQueries({ queryKey: getListCirclesQueryKey() });
          setIsCreateOpen(false);
          setName("");
          setContribution("");
          setEmails("");
          setImageUrl(null);
        }
      }
    );
  };

  if (circlesLoading || invitesLoading) {
    return <div className="p-8 text-center text-ink-400">Loading circles...</div>;
  }

  const visible = circles?.filter((c) => c.status !== "completed") ?? [];
  const inviteList = invites ?? [];

  return (
    <div className="mx-auto max-w-6xl space-y-6">
      <PageHeader
        eyebrow="Susu Circles"
        title="Your circles"
        description="Rotating savings with people you trust — every round held by an audited on-chain contract, not a person."
        action={
          <Dialog open={isCreateOpen} onOpenChange={setIsCreateOpen}>
            <DialogTrigger asChild>
              <Button>
                <Plus className="h-4 w-4" /> Start a circle
              </Button>
            </DialogTrigger>
            <DialogContent>
              <DialogHeader>
                <DialogTitle>Create new Susu Circle</DialogTitle>
              </DialogHeader>
              <form onSubmit={handleCreate} className="space-y-4 pt-4">
                <div className="space-y-2">
                  <Label>Name</Label>
                  <Input value={name} onChange={e => setName(e.target.value)} required placeholder="Family Savings" />
                </div>
                <div className="space-y-2">
                  <Label>Contribution Amount (USDC)</Label>
                  <Input type="number" value={contribution} onChange={e => setContribution(e.target.value)} required placeholder="100" />
                </div>
                <div className="space-y-2">
                  <Label>Frequency</Label>
                  <Select value={frequency} onValueChange={setFrequency}>
                    <SelectTrigger><SelectValue /></SelectTrigger>
                    <SelectContent>
                      <SelectItem value="weekly">Weekly</SelectItem>
                      <SelectItem value="biweekly">Bi-weekly</SelectItem>
                      <SelectItem value="monthly">Monthly</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-2">
                  <Label>Member Emails (comma separated)</Label>
                  <Input value={emails} onChange={e => setEmails(e.target.value)} placeholder="friend@example.com, cousin@example.com" />
                </div>
                <ImageUploadField
                  label="Circle picture (optional)"
                  hint="As the circle admin, add a photo to rally your group around the goal."
                  value={imageUrl}
                  onChange={setImageUrl}
                />
                <Button type="submit" className="w-full" disabled={createMutation.isPending}>
                  {createMutation.isPending ? "Creating…" : "Create Circle"}
                </Button>
              </form>
            </DialogContent>
          </Dialog>
        }
      />

      <Card className="flex items-center gap-4 border-jade-500/15 bg-jade-50/60 p-5">
        <span className="hidden h-11 w-11 shrink-0 items-center justify-center rounded-2xl bg-jade-500 text-white sm:flex">
          <ShieldCheck className="h-6 w-6" />
        </span>
        <p className="text-sm text-ink-700">
          <span className="font-semibold text-ink-900">How a Susu works:</span> everyone
          contributes a fixed amount each round, and one member receives the full pot. By the
          end, everyone has paid in equally and received one payout — all verifiable on Base.
        </p>
      </Card>

      {inviteList.length > 0 && (
        <Card className="border-jade-500/20 bg-jade-50/50 p-6">
          <div className="flex items-center gap-2">
            <Inbox className="h-5 w-5 text-jade-600" />
            <h2 className="font-display text-lg font-bold text-ink-900">
              Invitations ({inviteList.length})
            </h2>
          </div>
          <ul className="mt-4 space-y-3">
            {inviteList.map((inv) => (
              <li
                key={inv.id}
                className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-ink-900/[0.06] bg-white p-4"
              >
                <div>
                  <p className="font-semibold text-ink-900">{inv.circleName}</p>
                  <p className="text-xs text-ink-500">
                    {inv.inviterName} invited you · {formatMoney(inv.contributionCents)}/{inv.frequency}
                  </p>
                </div>
                <div className="flex items-center gap-2">
                  <ActionButton
                    onClick={() => {
                      acceptMutation.mutate({ id: inv.id }, {
                        onSuccess: () => {
                          queryClient.invalidateQueries({ queryKey: getListInvitesQueryKey() });
                          queryClient.invalidateQueries({ queryKey: getListCirclesQueryKey() });
                        }
                      });
                    }}
                    label="Accept"
                    pendingLabel="…"
                    size="sm"
                    pending={acceptMutation.isPending}
                  />
                  <ActionButton
                    onClick={() => {
                      declineMutation.mutate({ id: inv.id }, {
                        onSuccess: () => {
                          queryClient.invalidateQueries({ queryKey: getListInvitesQueryKey() });
                        }
                      });
                    }}
                    label="Decline"
                    pendingLabel="…"
                    size="sm"
                    variant="secondary"
                    pending={declineMutation.isPending}
                  />
                </div>
              </li>
            ))}
          </ul>
        </Card>
      )}

      <div className="grid gap-5 md:grid-cols-2">
        {visible.map((circle) => (
          <Link key={circle.id} href={`/circles/${circle.id}`} className="group block">
            <Card className="h-full overflow-hidden p-0 transition-[border-color,background-color] duration-150 group-hover:border-jade-500/25">
              {circle.imageUrl && (
                <div className="h-32 w-full overflow-hidden bg-mist">
                  <img
                    src={avatarSrc(circle.imageUrl)}
                    alt=""
                    className="h-full w-full object-cover transition-transform duration-200 group-hover:scale-[1.03]"
                  />
                </div>
              )}
              <div className="p-6">
              <div className="flex items-start justify-between">
                <div className="flex items-center gap-3">
                  <span className="flex h-11 w-11 items-center justify-center rounded-2xl bg-ink-900 text-white">
                    <Users className="h-5 w-5" />
                  </span>
                  <div>
                    <p className="font-semibold text-ink-900">{circle.name}</p>
                    <p className="text-xs capitalize text-ink-500">
                      {circle.frequency} · {circle.memberCount} members
                    </p>
                  </div>
                </div>
                <Badge tone={statusTone[circle.status as keyof typeof statusTone] ?? "neutral"} className="capitalize">
                  {circle.status}
                </Badge>
              </div>

              <div className="mt-5 grid grid-cols-2 gap-3">
                <div className="rounded-2xl bg-mist px-4 py-3">
                  <p className="font-mono text-[10px] uppercase tracking-wide text-ink-400">
                    Per round
                  </p>
                  <p className="font-semibold text-ink-900">
                    {formatMoney(circle.contributionCents)}
                  </p>
                </div>
                <div className="rounded-2xl bg-mist px-4 py-3">
                  <p className="font-mono text-[10px] uppercase tracking-wide text-ink-400">Pot</p>
                  <p className="font-semibold text-ink-900">{formatMoney(circle.potCents)}</p>
                </div>
              </div>

              {circle.status === "active" ? (
                <div className="mt-5">
                  <div className="flex items-center justify-between text-xs text-ink-500">
                    <span>
                      Round {circle.currentRound} of {circle.totalRounds}
                    </span>
                  </div>
                  <ProgressBar value={circle.currentRound} total={circle.totalRounds} className="mt-2" />
                </div>
              ) : (
                <div className="mt-5 flex items-center gap-2">
                  <span className="text-xs text-ink-500">Forming — waiting to start</span>
                </div>
              )}

              <div className="mt-5 inline-flex items-center gap-1.5 text-sm font-medium text-jade-600">
                View circle{" "}
                <ArrowRight className="h-4 w-4 transition-transform group-hover:translate-x-0.5" />
              </div>
              </div>
            </Card>
          </Link>
        ))}

        <button
          onClick={() => setIsCreateOpen(true)}
          className="flex min-h-[230px] flex-col items-center justify-center gap-3 rounded-2xl border-2 border-dashed border-ink-900/12 p-6 text-ink-400 transition-[color,border-color,transform] duration-150 hover:border-jade-500/35 hover:text-jade-600 active:scale-[0.99] focus-ring"
        >
          <span className="flex h-12 w-12 items-center justify-center rounded-xl border border-ink-900/8 bg-white">
            <Plus className="h-6 w-6" />
          </span>
          <span className="text-sm font-semibold">Start a new circle</span>
          <span className="max-w-[200px] text-center text-xs">
            Invite friends or family and set your contribution
          </span>
        </button>
      </div>

      <Eyebrow className="pt-4 text-center text-ink-300">Save Now · Grow Together</Eyebrow>
    </div>
  );
}
