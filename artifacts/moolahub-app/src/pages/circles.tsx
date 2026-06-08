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
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import { ImageUploadField } from "@/components/app/ImageUploadField";
import { avatarSrc, cn } from "@/lib/utils";
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
  const [type, setType] = useState<"rotation" | "accumulation">("rotation");
  const [contribution, setContribution] = useState("");
  const [numRounds, setNumRounds] = useState("6");
  const [frequency, setFrequency] = useState("weekly");
  const [emails, setEmails] = useState("");
  const [imageUrl, setImageUrl] = useState<string | null>(null);

  const contributionAmount = parseFloat(contribution) || 0;
  const emailCount = emails.split(",").map((e) => e.trim()).filter(Boolean).length;
  const estMembers = emailCount + 1; // organizer + invitees
  const roundsNum = Math.max(0, parseInt(numRounds, 10) || 0);
  // Rotation: receive the full pot when it's your turn (pay × members).
  // Accumulation: get your own savings back at the end (pay × rounds).
  const receiveAmount =
    type === "accumulation" ? contributionAmount * roundsNum : contributionAmount * estMembers;

  const handleCreate = (e: React.FormEvent) => {
    e.preventDefault();
    createMutation.mutate(
      { 
        data: { 
          name, 
          type,
          contributionCents: Math.floor(contributionAmount * 100), 
          numRounds: type === "accumulation" ? roundsNum : undefined,
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
          setType("rotation");
          setContribution("");
          setNumRounds("6");
          setEmails("");
          setImageUrl(null);
        }
      }
    );
  };

  if (circlesLoading || invitesLoading) {
    return <div className="p-8 text-center text-muted-foreground">Loading your circles…</div>;
  }

  const visible = circles?.filter((c) => c.status !== "completed") ?? [];
  const inviteList = invites ?? [];

  return (
    <div className="mx-auto max-w-6xl space-y-6">
      <PageHeader
        eyebrow="Susu Circles"
        title="Your circles"
        description="Rotating savings with people you trust. Every round is held by an on-chain contract, not a person."
        action={
          <Dialog open={isCreateOpen} onOpenChange={setIsCreateOpen}>
            <DialogTrigger asChild>
              <Button>
                <Plus className="h-4 w-4" /> Start a circle
              </Button>
            </DialogTrigger>
            <DialogContent>
              <DialogHeader>
                <DialogTitle>New circle</DialogTitle>
              </DialogHeader>
              <form onSubmit={handleCreate} className="space-y-4 pt-4">
                <div className="space-y-2">
                  <Label>Name</Label>
                  <Input value={name} onChange={e => setName(e.target.value)} required placeholder="e.g. Family savings" />
                </div>
                <div className="space-y-2">
                  <Label>Circle type</Label>
                  <RadioGroup
                    value={type}
                    onValueChange={(v) => setType(v as "rotation" | "accumulation")}
                    className="gap-2"
                  >
                    <label
                      htmlFor="type-rotation"
                      className={cn(
                        "flex cursor-pointer items-start gap-3 rounded-2xl border p-3 transition-colors",
                        type === "rotation" ? "border-jade-500/40 bg-jade-50/60" : "border-border",
                      )}
                    >
                      <RadioGroupItem value="rotation" id="type-rotation" className="mt-0.5" />
                      <span className="text-sm">
                        <span className="font-semibold text-foreground">Rotation</span>
                        <span className="block text-xs text-muted-foreground">
                          Take turns. Everyone pays each round, and one member receives the full pot until all have had a turn.
                        </span>
                      </span>
                    </label>
                    <label
                      htmlFor="type-accumulation"
                      className={cn(
                        "flex cursor-pointer items-start gap-3 rounded-2xl border p-3 transition-colors",
                        type === "accumulation" ? "border-jade-500/40 bg-jade-50/60" : "border-border",
                      )}
                    >
                      <RadioGroupItem value="accumulation" id="type-accumulation" className="mt-0.5" />
                      <span className="text-sm">
                        <span className="font-semibold text-foreground">Accumulation</span>
                        <span className="block text-xs text-muted-foreground">
                          Save together. Everyone pays into one shared pot and gets their own savings back at the end.
                        </span>
                      </span>
                    </label>
                  </RadioGroup>
                </div>
                <div className="space-y-2">
                  <Label>Contribution per round (USDC)</Label>
                  <Input type="number" value={contribution} onChange={e => setContribution(e.target.value)} required placeholder="100" />
                </div>
                {type === "accumulation" && (
                  <div className="space-y-2">
                    <Label>Number of rounds</Label>
                    <Input
                      type="number"
                      min={2}
                      value={numRounds}
                      onChange={(e) => setNumRounds(e.target.value)}
                      required
                      placeholder="6"
                    />
                  </div>
                )}
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
                  <Label>Member emails <span className="text-xs font-normal text-muted-foreground">(up to 19, comma-separated)</span></Label>
                  <Input value={emails} onChange={e => setEmails(e.target.value)} placeholder="friend@example.com, cousin@example.com" />
                  {emailCount > 19 && (
                    <p className="text-xs text-destructive">
                      Too many members — a circle can have at most 20 people (you + 19 invitees).
                    </p>
                  )}
                </div>
                <div className="grid grid-cols-2 gap-3 rounded-2xl border border-jade-500/15 bg-jade-50/50 p-4">
                  <div>
                    <p className="font-mono text-[10px] uppercase tracking-wide text-muted-foreground">You pay per round</p>
                    <p className="font-semibold text-foreground">{formatMoney(Math.round(contributionAmount * 100))}</p>
                  </div>
                  <div>
                    <p className="font-mono text-[10px] uppercase tracking-wide text-muted-foreground">
                      {type === "accumulation" ? "You receive at end" : "You receive"}
                    </p>
                    <p className="font-semibold text-foreground">{formatMoney(Math.round(receiveAmount * 100))}</p>
                  </div>
                  <p className="col-span-2 text-xs text-muted-foreground">
                    {type === "accumulation"
                      ? `Your own savings back after ${roundsNum || 0} rounds.`
                      : "Estimate based on members so far. Finalized when the circle starts."}
                  </p>
                </div>
                <ImageUploadField
                  label="Circle picture (optional)"
                  hint="As the circle admin, add a photo to rally your group around the goal."
                  value={imageUrl}
                  onChange={setImageUrl}
                />
                <Button type="submit" className="w-full" disabled={createMutation.isPending || emailCount > 19}>
                  {createMutation.isPending ? "Creating…" : "Create circle"}
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
        <p className="text-sm text-foreground">
          <span className="font-semibold text-foreground">How a Susu works:</span> everyone
          contributes a fixed amount each round. In a <span className="font-medium text-foreground">rotation</span>{" "}
          circle, one member receives the full pot each round until everyone has had a turn. In an{" "}
          <span className="font-medium text-foreground">accumulation</span> circle, everyone saves into a shared
          pot and gets their own savings back at the end. Everything is verifiable on Base.
        </p>
      </Card>

      {inviteList.length > 0 && (
        <Card className="border-jade-500/20 bg-jade-50/50 p-6">
          <div className="flex items-center gap-2">
            <Inbox className="h-5 w-5 text-jade-600 dark:text-jade-400" />
            <h2 className="font-display text-lg font-bold text-foreground">
              Invitations ({inviteList.length})
            </h2>
          </div>
          <ul className="mt-4 space-y-3">
            {inviteList.map((inv) => (
              <li
                key={inv.id}
                className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-border bg-card p-4"
              >
                <div>
                  <p className="font-semibold text-foreground">{inv.circleName}</p>
                  <p className="text-xs text-muted-foreground">
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
                <div className="h-32 w-full overflow-hidden bg-background">
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
                    <p className="font-semibold text-foreground">{circle.name}</p>
                    <p className="text-xs capitalize text-muted-foreground">
                      {circle.frequency} · {circle.memberCount} members
                    </p>
                  </div>
                </div>
                <div className="flex flex-col items-end gap-1.5">
                  <Badge tone={statusTone[circle.status as keyof typeof statusTone] ?? "neutral"} className="capitalize">
                    {circle.status}
                  </Badge>
                  <Badge tone="neutral">
                    {circle.type === "accumulation" ? "Accumulation" : "Rotation"}
                  </Badge>
                </div>
              </div>

              <div className="mt-5 grid grid-cols-2 gap-3">
                <div className="rounded-2xl bg-background px-4 py-3">
                  <p className="font-mono text-[10px] uppercase tracking-wide text-muted-foreground">
                    Per round
                  </p>
                  <p className="font-semibold text-foreground">
                    {formatMoney(circle.contributionCents)}
                  </p>
                </div>
                <div className="rounded-2xl bg-background px-4 py-3">
                  <p className="font-mono text-[10px] uppercase tracking-wide text-muted-foreground">You receive</p>
                  <p className="font-semibold text-foreground">{formatMoney(circle.payoutCents)}</p>
                </div>
              </div>

              {circle.status === "active" ? (
                <div className="mt-5">
                  <div className="flex items-center justify-between text-xs text-muted-foreground">
                    <span>
                      Round {circle.currentRound} of {circle.totalRounds}
                    </span>
                  </div>
                  <ProgressBar value={circle.currentRound} total={circle.totalRounds} className="mt-2" />
                </div>
              ) : (
                <div className="mt-5 flex items-center gap-2">
                  <span className="text-xs text-muted-foreground">Forming. Waiting to start.</span>
                </div>
              )}

              <div className="mt-5 inline-flex items-center gap-1.5 text-sm font-medium text-jade-600 dark:text-jade-400">
                View circle{" "}
                <ArrowRight className="h-4 w-4 transition-transform group-hover:translate-x-0.5" />
              </div>
              </div>
            </Card>
          </Link>
        ))}

        <button
          onClick={() => setIsCreateOpen(true)}
          className="flex min-h-[230px] flex-col items-center justify-center gap-3 rounded-2xl border-2 border-dashed border-border p-6 text-muted-foreground transition-[color,border-color,transform] duration-150 hover:border-jade-500/35 hover:text-jade-600 active:scale-[0.99] focus-ring"
        >
          <span className="flex h-12 w-12 items-center justify-center rounded-xl border border-border bg-card">
            <Plus className="h-6 w-6" />
          </span>
          <span className="text-sm font-semibold">Start a circle</span>
          <span className="max-w-[200px] text-center text-xs">
            Invite friends or family and set your contribution
          </span>
        </button>
      </div>

      <Eyebrow className="pt-4 text-center text-muted-foreground">Save today · Reach it together</Eyebrow>
    </div>
  );
}
