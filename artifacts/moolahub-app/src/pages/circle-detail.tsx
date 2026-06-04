import {
  Users,
  ShieldCheck,
  CheckCircle2,
  Circle as CircleIcon,
  CalendarClock,
  Crown,
  Mail,
  UserPlus,
  Rocket
} from "lucide-react";
import { Card, Badge, Avatar, ProgressBar } from "@/components/ui";
import { BackLink, TxTag } from "@/components/app/bits";
import { ActionButton, InviteForm } from "@/components/app/forms";
import { useGetCircle, useStartCircle, useContributeToCircle, useInviteToCircle, getGetCircleQueryKey } from "@workspace/api-client-react";
import { formatMoney, truncateAddress, cn } from "@/lib/utils";
import { useQueryClient } from "@tanstack/react-query";
import { useParams } from "wouter";

export default function CircleDetailPage() {
  const { id } = useParams();
  const { data: circle, isLoading } = useGetCircle(id!, { query: { enabled: !!id, queryKey: getGetCircleQueryKey(id!) } });
  
  const queryClient = useQueryClient();
  const startMutation = useStartCircle();
  const contributeMutation = useContributeToCircle();
  const inviteMutation = useInviteToCircle();

  if (isLoading) return <div className="p-8 text-center text-ink-400">Loading circle...</div>;
  if (!circle) return <div className="p-8 text-center text-ink-400">Circle not found</div>;

  const isPending = circle.status === "pending";
  const isActive = circle.status === "active";
  const isAccumulation = circle.type === "accumulation";
  const allAccepted = circle.members.every(m => m.state === "accepted");
  const isCreator = true; // simplifying logic, could use actual creator state

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
              <p className="text-sm capitalize text-white/55">
                {circle.frequency} · {circle.members.length} members
                {isPending
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
              <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-white/45">
                {s.label}
              </p>
              <p className="mt-1 font-display text-xl font-bold">{s.value}</p>
            </div>
          ))}
        </div>

        <div className="mt-6 flex flex-wrap items-center gap-4">
          {isActive && circle.myContributionStatus !== "paid" ? (
            <ActionButton
              onClick={() => {
                contributeMutation.mutate({ id: circle.id }, {
                  onSuccess: () => queryClient.invalidateQueries({ queryKey: getGetCircleQueryKey(circle.id) })
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
            <Badge tone="amber">Circle is still forming</Badge>
          )}
        </div>
      </Card>

      {/* ------------------------------------------------- forming controls */}
      {isPending && (
        <Card className="p-6">
          <div className="flex items-center gap-2">
            <UserPlus className="h-5 w-5 text-jade-600" />
            <h2 className="font-display text-lg font-bold text-ink-900">Build your circle</h2>
          </div>
          <p className="mt-1 text-sm text-ink-500">
            {isAccumulation
              ? `Invite people by email. Everyone saves into one shared pot for ${circle.totalRounds} rounds, then gets their savings back. Start the circle once everyone's in.`
              : "Invite people by email. Rounds equal members — everyone gets exactly one payout. Start the circle once everyone's in."}
          </p>

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

          {isCreator && (
            <div className="mt-6 flex flex-wrap items-center gap-3 border-t border-ink-900/[0.06] pt-5">
              {allAccepted && circle.members.length > 1 ? (
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
                <p className="inline-flex items-center gap-2 text-sm text-ink-500">
                  <Rocket className="h-4 w-4 text-ink-400" />
                  Invite at least one more member and wait for them to accept to start.
                </p>
              )}
            </div>
          )}
        </Card>
      )}

      <div className="grid gap-6 lg:grid-cols-5">
        {/* ------------------------------------------------ payout schedule */}
        <Card className="p-6 lg:col-span-3">
          <div className="flex items-center gap-2">
            <CalendarClock className="h-5 w-5 text-jade-600" />
            <h2 className="font-display text-lg font-bold text-ink-900">
              {isAccumulation ? "Members" : "Payout schedule"}
            </h2>
          </div>
          <p className="mt-1 text-sm text-ink-500">
            {isAccumulation
              ? `Everyone saves into one shared pot. After ${circle.totalRounds} rounds, each member gets their own savings back — locked on-chain.`
              : "The rotation is locked on-chain — everyone knows who receives the pot, and when."}
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
                    current ? "border-jade-500/30 bg-jade-50" : "border-ink-900/[0.06] bg-white",
                  )}
                >
                  {!isAccumulation && (
                    <span className="font-mono text-xs text-ink-400">{m.payoutRound}</span>
                  )}
                  {done ? (
                    <CheckCircle2 className="h-5 w-5 text-jade-500" />
                  ) : current ? (
                    <Crown className="h-5 w-5 text-jade-600" />
                  ) : (
                    <CircleIcon className="h-5 w-5 text-ink-300" />
                  )}
                  <Avatar name={m.name} tone={isYou ? "jade" : "ink"} className="h-8 w-8" />
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-semibold text-ink-900">
                      {m.name} {isYou && <span className="text-jade-600">(you)</span>}
                    </p>
                    <p className="text-xs text-ink-500 capitalize">
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
            <h2 className="font-display text-lg font-bold text-ink-900">Round progress</h2>
            <p className="mt-3 text-sm text-ink-500">
              {circle.currentRound} of {circle.totalRounds} rounds
            </p>
            <ProgressBar value={circle.currentRound} total={circle.totalRounds} className="mt-2" />
          </Card>
        </div>
      </div>
    </div>
  );
}
