import {
  Users,
  ShieldCheck,
  CheckCircle2,
  Circle as CircleIcon,
  CalendarClock,
  Crown,
  Mail,
  UserPlus,
  Rocket,
  Link2,
  ExternalLink,
  Trash2
} from "lucide-react";
import { Card, Badge, Avatar, ProgressBar } from "@/components/ui";
import { BackLink } from "@/components/app/bits";
import { ActionButton, InviteForm } from "@/components/app/forms";
import { useGetCircle, useStartCircle, useContributeToCircle, useInviteToCircle, useDeleteCircle, getGetCircleQueryKey, getListCirclesQueryKey, getGetStreaksQueryKey } from "@workspace/api-client-react";
import { toast } from "@/hooks/use-toast";
import { formatMoney, truncateAddress, apiErrorMessage, cn } from "@/lib/utils";
import { useQueryClient } from "@tanstack/react-query";
import { useParams, useLocation } from "wouter";
import { useState } from "react";

export default function CircleDetailPage() {
  const { id } = useParams();
  const [, navigate] = useLocation();
  const { data: circle, isLoading } = useGetCircle(id!, { query: { enabled: !!id, queryKey: getGetCircleQueryKey(id!) } });
  
  const queryClient = useQueryClient();
  const startMutation = useStartCircle();
  const contributeMutation = useContributeToCircle();
  const inviteMutation = useInviteToCircle();
  const deleteMutation = useDeleteCircle();
  const [confirmDelete, setConfirmDelete] = useState(false);

  if (isLoading) return <div className="p-8 text-center text-muted-foreground">Loading circle…</div>;
  if (!circle) return <div className="p-8 text-center text-muted-foreground">We couldn't find that circle.</div>;

  const isForming = circle.status === "forming";
  const isActive = circle.status === "active";
  const isAccumulation = circle.type === "accumulation";
  const isCreator = circle.isCreator ?? false;
  const canStart = circle.canStart ?? false;
  const canInvite = circle.canInvite ?? false;
  const canDelete = circle.canDelete ?? false;

  return (
    <div className="mx-auto max-w-5xl space-y-6">
      <BackLink href="/circles" label="All circles" />

      {/* ----------------------------------------------------------- header */}
      <Card className="relative isolate overflow-hidden border-0 bg-ink-950 p-6 text-white lg:p-8">
        <div className="absolute inset-0 -z-10 bg-grid-dark [background-size:32px_32px] [mask-image:radial-gradient(70%_80%_at_90%_0%,black,transparent)]" />

        <div className="flex flex-wrap items-start justify-between gap-4">
          <div className="flex items-center gap-4">
            <span className="flex h-14 w-14 items-center justify-center rounded-2xl bg-white/10">
              <Users className="h-7 w-7 text-jade-400" />
            </span>
            <div>
              <h1 className="font-display text-2xl font-bold">{circle.name}</h1>
              <p className="text-sm capitalize text-white/70">
                {circle.frequency} · {circle.members.length} members
                {isForming
                  ? " · forming"
                  : ` · Round ${circle.currentRound} of ${circle.totalRounds}`}
              </p>
            </div>
          </div>
          <div className="flex flex-col items-end gap-1.5">
            <Badge tone="jade" className="bg-jade-500/15 capitalize text-jade-300 ring-jade-400/20">
              {circle.status}
            </Badge>
            <Badge tone="neutral" className="bg-white/10 text-white/70 ring-white/15">
              {isAccumulation ? "Accumulation" : "Rotation"}
            </Badge>
            {circle.contractAddress && (
              <Badge tone="jade" className="bg-jade-500/15 text-jade-300 ring-jade-400/20">
                <Link2 className="h-3.5 w-3.5" /> On-chain
              </Badge>
            )}
          </div>
        </div>

        <div className="mt-6 grid grid-cols-2 gap-4 sm:grid-cols-4">
          {[
            { label: "Per round", value: formatMoney(circle.contributionCents) },
            { label: "You receive", value: formatMoney(circle.payoutCents) },
            isAccumulation
              ? { label: "Rounds", value: `${circle.totalRounds}` }
              : { label: "Your position", value: circle.myPayoutRound ? `#${circle.myPayoutRound}` : "—" },
            {
              label: "Started",
              value: circle.startDate ? new Date(circle.startDate).toLocaleDateString("en-US", {
                month: "short",
                day: "numeric",
              }) : "—",
            },
          ].map((s) => (
            <div key={s.label}>
              <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-white/60">
                {s.label}
              </p>
              <p className="mt-1 font-display text-xl font-bold">{s.value}</p>
            </div>
          ))}
        </div>

        <div className="mt-6 flex flex-wrap items-center gap-4">
          {(circle.canContribute ?? (isActive && circle.myContributionStatus !== "paid")) ? (
            <ActionButton
              onClick={() => {
                contributeMutation.mutate({ id: circle.id }, {
                  onSuccess: () => {
                    queryClient.invalidateQueries({ queryKey: getGetCircleQueryKey(circle.id) });
                    queryClient.invalidateQueries({ queryKey: getGetStreaksQueryKey() });
                    toast({
                      title: "Streak kept alive 🔥",
                      description: "Nice — that contribution counts toward your savings streak.",
                    });
                  }
                });
              }}
              label={`Contribute ${formatMoney(circle.contributionCents)}`}
              pendingLabel="Submitting…"
              size="sm"
              pending={contributeMutation.isPending}
            />
          ) : isActive ? (
            <Badge tone="jade" className="bg-jade-500/15 text-jade-300 ring-jade-400/20">
              <CheckCircle2 className="h-3.5 w-3.5" /> Contributed this round
            </Badge>
          ) : (
            <Badge tone="amber">This circle hasn't started yet</Badge>
          )}
        </div>
      </Card>

      {/* ------------------------------------------------- forming controls */}
      {isForming && (
        <Card className="p-6">
          <div className="flex items-center gap-2">
            <UserPlus className="h-5 w-5 text-jade-600 dark:text-jade-400" />
            <h2 className="font-display text-lg font-bold text-foreground">Build your circle</h2>
          </div>
          <p className="mt-1 text-sm text-muted-foreground">
            {isAccumulation
              ? `Invite people by email. Everyone saves into one shared pot for ${circle.totalRounds} rounds, then gets their savings back. Start the circle once everyone's in.`
              : circle.targetMembers
                ? `Invite people by email. ${circle.members.length} of ${circle.targetMembers} have joined — the circle starts automatically the moment the last person joins.`
                : "Invite people by email. Rounds equal members, so everyone gets exactly one payout. Start the circle once everyone's in."}
          </p>

          {canInvite && (
            <div className="mt-4 max-w-md">
              <InviteForm 
                onSubmit={(email) => {
                  inviteMutation.mutate({ id: circle.id, data: { email } }, {
                    onSuccess: () => queryClient.invalidateQueries({ queryKey: getGetCircleQueryKey(circle.id) })
                  });
                }}
                pending={inviteMutation.isPending}
                ok={inviteMutation.isSuccess ? "Sent" : null}
              />
            </div>
          )}

          {isCreator && (
            <div className="mt-6 flex flex-wrap items-center gap-3 border-t border-border pt-5">
              {canStart ? (
                <ActionButton
                  onClick={() => {
                    startMutation.mutate({ id: circle.id }, {
                      onSuccess: () => queryClient.invalidateQueries({ queryKey: getGetCircleQueryKey(circle.id) })
                    });
                  }}
                  label="Start circle"
                  pendingLabel="Starting…"
                  pending={startMutation.isPending}
                />
              ) : (
                <p className="inline-flex items-center gap-2 text-sm text-muted-foreground">
                  <Rocket className="h-4 w-4 text-muted-foreground" />
                  Invite at least one more member to start the circle.
                </p>
              )}
            </div>
          )}
        </Card>
      )}

      {/* ----------------------------------------------------- delete circle */}
      {canDelete && (
        <Card className="border-rose-500/20 p-6">
          <h2 className="font-display text-lg font-bold text-foreground">Delete circle</h2>
          <p className="mt-1 text-sm text-muted-foreground">
            No one else has joined yet, so you can delete this circle. Once another member
            joins, it can't be deleted. This permanently removes the circle and any pending invites.
          </p>
          {deleteMutation.error && (
            <p className="mt-3 text-sm text-rose-600">{apiErrorMessage(deleteMutation.error)}</p>
          )}
          <div className="mt-4 flex flex-wrap items-center gap-3">
            {!confirmDelete ? (
              <button
                type="button"
                onClick={() => setConfirmDelete(true)}
                className="inline-flex items-center gap-2 rounded-xl border border-rose-500/30 bg-card px-4 py-2 text-sm font-medium text-rose-600 transition hover:bg-rose-50"
              >
                <Trash2 className="h-4 w-4" /> Delete circle
              </button>
            ) : (
              <>
                <button
                  type="button"
                  disabled={deleteMutation.isPending}
                  onClick={() =>
                    deleteMutation.mutate(
                      { id: circle.id },
                      {
                        onSuccess: () => {
                          queryClient.invalidateQueries({ queryKey: getListCirclesQueryKey() });
                          navigate("/circles");
                        },
                      },
                    )
                  }
                  className="inline-flex items-center gap-2 rounded-xl bg-rose-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-rose-700 disabled:opacity-60"
                >
                  <Trash2 className="h-4 w-4" />
                  {deleteMutation.isPending ? "Deleting…" : "Confirm delete"}
                </button>
                <button
                  type="button"
                  disabled={deleteMutation.isPending}
                  onClick={() => setConfirmDelete(false)}
                  className="rounded-xl border border-border bg-card px-4 py-2 text-sm font-medium text-muted-foreground transition hover:bg-accent"
                >
                  Cancel
                </button>
              </>
            )}
          </div>
        </Card>
      )}

      <div className="grid gap-6 lg:grid-cols-5">
        {/* ------------------------------------------------ payout schedule */}
        <Card className="p-6 lg:col-span-3">
          <div className="flex items-center gap-2">
            <CalendarClock className="h-5 w-5 text-jade-600 dark:text-jade-400" />
            <h2 className="font-display text-lg font-bold text-foreground">
              {isAccumulation ? "Members" : "Payout schedule"}
            </h2>
          </div>
          <p className="mt-1 text-sm text-muted-foreground">
            {isAccumulation
              ? `Everyone saves into one shared pot. After ${circle.totalRounds} rounds, each member gets their own savings back, locked on-chain.`
              : "The rotation is locked on-chain, so everyone knows who receives the pot, and when."}
          </p>

          <ol className="mt-5 space-y-2">
            {circle.members.map((m) => {
              const done = m.paidOut;
              const current = !isAccumulation && isActive && circle.currentRound === m.payoutRound;
              const isYou = m.payoutRound === circle.myPayoutRound;

              return (
                <li
                  key={m.id}
                  className={cn(
                    "flex items-center gap-3 rounded-2xl border px-4 py-3",
                    current ? "border-jade-500/30 bg-jade-50 dark:bg-jade-500/15" : "border-border bg-card",
                  )}
                >
                  {!isAccumulation && (
                    <span className="font-mono text-xs text-muted-foreground">{m.payoutRound}</span>
                  )}
                  {done ? (
                    <CheckCircle2 className="h-5 w-5 text-jade-500" />
                  ) : current ? (
                    <Crown className="h-5 w-5 text-jade-600 dark:text-jade-400" />
                  ) : (
                    <CircleIcon className="h-5 w-5 text-muted-foreground" />
                  )}
                  <Avatar name={m.name} tone={isYou ? "jade" : "ink"} className="h-8 w-8" />
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-semibold text-foreground">
                      {m.name} {isYou && <span className="text-jade-600 dark:text-jade-400">(you)</span>}
                    </p>
                    <p className="text-xs text-muted-foreground capitalize">
                      {isAccumulation
                        ? done
                          ? "Savings returned"
                          : "Saving"
                        : done
                          ? "Received pot"
                          : current
                            ? "Receiving now"
                            : m.state}
                    </p>
                  </div>
                  {current && <Badge tone="jade">Current</Badge>}
                </li>
              );
            })}
          </ol>
        </Card>

        {/* ------------------------------------------ contribution history */}
        <div className="space-y-6 lg:col-span-2">
          <Card className="p-6">
            <h2 className="font-display text-lg font-bold text-foreground">Round progress</h2>
            <p className="mt-3 text-sm text-muted-foreground">
              {circle.currentRound} of {circle.totalRounds} rounds
            </p>
            <ProgressBar value={circle.currentRound} total={circle.totalRounds} className="mt-2" />
          </Card>

          {circle.contractAddress && (
            <Card className="p-6">
              <div className="flex items-center gap-2">
                <Link2 className="h-5 w-5 text-jade-600 dark:text-jade-400" />
                <h2 className="font-display text-lg font-bold text-foreground">On-chain escrow</h2>
              </div>
              <p className="mt-1 text-sm text-muted-foreground">
                Contributions settle into this Susu escrow on Monad. A{" "}
                {((circle.feeBps ?? 0) / 100).toFixed(0)}% protocol fee is taken from each payout.
              </p>
              <a
                href={`${circle.explorerUrl ?? "https://testnet.monadvision.com"}/address/${circle.contractAddress}`}
                target="_blank"
                rel="noreferrer"
                className="mt-4 inline-flex items-center gap-2 rounded-xl border border-border bg-card px-3 py-2 font-mono text-xs text-foreground transition hover:border-jade-500/40 hover:text-jade-700"
              >
                {truncateAddress(circle.contractAddress)}
                <ExternalLink className="h-3.5 w-3.5" />
              </a>
            </Card>
          )}

          {(circle.history?.length ?? 0) > 0 && (
            <Card className="p-6">
              <h2 className="font-display text-lg font-bold text-foreground">Your contributions</h2>
              <ul className="mt-4 space-y-2">
                {circle.history!.map((h) => (
                  <li
                    key={h.id}
                    className="flex items-center justify-between gap-3 rounded-2xl border border-border bg-card px-4 py-3"
                  >
                    <div className="min-w-0">
                      <p className="text-sm font-semibold text-foreground">Round {h.round}</p>
                      <p className="text-xs text-muted-foreground">{formatMoney(h.amountCents)}</p>
                    </div>
                    {h.txHash ? (
                      <a
                        href={`${circle.explorerUrl ?? "https://testnet.monadvision.com"}/tx/${h.txHash}`}
                        target="_blank"
                        rel="noreferrer"
                        className="inline-flex items-center gap-1.5 font-mono text-xs text-jade-700 dark:text-jade-300 transition hover:text-jade-800"
                      >
                        {truncateAddress(h.txHash)}
                        <ExternalLink className="h-3.5 w-3.5" />
                      </a>
                    ) : (
                      <Badge tone="neutral" className="capitalize">{h.status}</Badge>
                    )}
                  </li>
                ))}
              </ul>
            </Card>
          )}
        </div>
      </div>
    </div>
  );
}
