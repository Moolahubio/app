import { notFound } from "next/navigation";
import {
  Users,
  ShieldCheck,
  CheckCircle2,
  Circle as CircleIcon,
  CalendarClock,
  Crown,
} from "lucide-react";
import { Card, Badge, Avatar, ProgressBar } from "@/components/ui";
import { BackLink, TxTag } from "@/components/app/bits";
import { Mail, UserPlus, Rocket } from "lucide-react";
import { ActionButton, InviteForm } from "@/components/app/forms";
import { requireUser } from "@/lib/server/auth";
import { getCircleDetail } from "@/lib/server/circles";
import { contributeAction, startCircleAction } from "@/app/(app)/actions";
import { formatMoney, cn, truncateAddress } from "@/lib/utils";

export default async function CircleDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const user = await requireUser();
  const circle = await getCircleDetail(user.id, id);
  if (!circle) notFound();

  return (
    <div className="mx-auto max-w-5xl space-y-6">
      <BackLink href="/circles" label="All circles" />

      {/* ----------------------------------------------------------- header */}
      <Card className="relative isolate overflow-hidden border-0 bg-ink-950 p-6 text-white lg:p-8">
        <div className="absolute inset-0 -z-10 bg-grid-dark [background-size:32px_32px] [mask-image:radial-gradient(70%_80%_at_90%_0%,black,transparent)]" />
        <div className="absolute -right-10 -top-16 -z-10 h-64 w-64 rounded-full bg-jade-500/20 blur-[90px]" />

        <div className="flex flex-wrap items-start justify-between gap-4">
          <div className="flex items-center gap-4">
            <span className="flex h-14 w-14 items-center justify-center rounded-2xl bg-white/10">
              <Users className="h-7 w-7 text-jade-400" />
            </span>
            <div>
              <h1 className="font-display text-2xl font-bold">{circle.name}</h1>
              <p className="text-sm capitalize text-white/55">
                {circle.frequency} · {circle.memberCount} members
                {circle.status === "forming"
                  ? " · forming"
                  : ` · Round ${circle.currentRound} of ${circle.totalRounds}`}
              </p>
            </div>
          </div>
          <Badge tone="jade" className="bg-jade-500/15 capitalize text-jade-300 ring-jade-400/20">
            {circle.status}
          </Badge>
        </div>

        <div className="mt-6 grid grid-cols-2 gap-4 sm:grid-cols-4">
          {[
            { label: "Per round", value: formatMoney(circle.contributionCents) },
            { label: "Pot payout", value: formatMoney(circle.potCents) },
            { label: "Your position", value: circle.myPosition ? `#${circle.myPosition}` : "—" },
            {
              label: "Next due",
              value: circle.nextContributionDate.toLocaleDateString("en-US", {
                month: "short",
                day: "numeric",
              }),
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
          {circle.canContribute ? (
            <ActionButton
              action={contributeAction}
              hidden={{ circleId: circle.id }}
              label={`Contribute ${formatMoney(circle.contributionCents)}`}
              pendingLabel="Submitting…"
              size="sm"
            />
          ) : circle.status === "active" ? (
            <Badge tone="jade" className="bg-jade-500/15 text-jade-300 ring-jade-400/20">
              <CheckCircle2 className="h-3.5 w-3.5" /> Contributed this round
            </Badge>
          ) : (
            <Badge tone="amber">Circle is still forming</Badge>
          )}
          {circle.contractAddress && (
            <span className="inline-flex items-center gap-1.5 font-mono text-xs text-white/50">
              <ShieldCheck className="h-4 w-4 text-jade-400" />
              Contract {truncateAddress(circle.contractAddress, 6, 4)}
            </span>
          )}
        </div>
      </Card>

      {/* ------------------------------------------------- forming controls */}
      {circle.status === "forming" && (circle.canInvite || circle.pendingInvites.length > 0) && (
        <Card className="p-6">
          <div className="flex items-center gap-2">
            <UserPlus className="h-5 w-5 text-jade-600" />
            <h2 className="font-display text-lg font-bold text-ink-900">Build your circle</h2>
          </div>
          <p className="mt-1 text-sm text-ink-500">
            Invite people by email. Rounds equal members — everyone gets exactly one payout. Start
            the circle once everyone&apos;s in.
          </p>

          {circle.canInvite && (
            <div className="mt-4 max-w-md">
              <InviteForm circleId={circle.id} />
            </div>
          )}

          {circle.pendingInvites.length > 0 && (
            <div className="mt-5">
              <p className="font-mono text-[10px] uppercase tracking-[0.18em] text-ink-400">
                Pending invitations
              </p>
              <ul className="mt-2 space-y-2">
                {circle.pendingInvites.map((inv) => (
                  <li
                    key={inv.id}
                    className="flex items-center gap-2 rounded-2xl border border-ink-900/[0.06] bg-mist px-4 py-2.5"
                  >
                    <Mail className="h-4 w-4 text-ink-400" />
                    <span className="text-sm text-ink-700">{inv.email}</span>
                    <Badge tone="amber" className="ml-auto">
                      Pending
                    </Badge>
                  </li>
                ))}
              </ul>
            </div>
          )}

          {circle.isCreator && (
            <div className="mt-6 flex flex-wrap items-center gap-3 border-t border-ink-900/[0.06] pt-5">
              {circle.canStart ? (
                <ActionButton
                  action={startCircleAction}
                  hidden={{ circleId: circle.id }}
                  label="Start circle"
                  pendingLabel="Starting…"
                />
              ) : (
                <p className="inline-flex items-center gap-2 text-sm text-ink-500">
                  <Rocket className="h-4 w-4 text-ink-400" />
                  Invite at least one more member to start.
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
            <h2 className="font-display text-lg font-bold text-ink-900">Payout schedule</h2>
          </div>
          <p className="mt-1 text-sm text-ink-500">
            The rotation is locked on-chain — everyone knows who receives the pot, and when.
          </p>

          <ol className="mt-5 space-y-2">
            {circle.members.map((m) => {
              const done = m.state === "paid";
              const current = m.state === "current";
              return (
                <li
                  key={m.position}
                  className={cn(
                    "flex items-center gap-3 rounded-2xl border px-4 py-3",
                    current ? "border-jade-500/30 bg-jade-50" : "border-ink-900/[0.06] bg-white",
                  )}
                >
                  <span className="font-mono text-xs text-ink-400">{m.position}</span>
                  {done ? (
                    <CheckCircle2 className="h-5 w-5 text-jade-500" />
                  ) : current ? (
                    <Crown className="h-5 w-5 text-jade-600" />
                  ) : (
                    <CircleIcon className="h-5 w-5 text-ink-300" />
                  )}
                  <Avatar name={m.name} tone={m.isYou ? "jade" : "ink"} className="h-8 w-8" />
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-semibold text-ink-900">
                      {m.name} {m.isYou && <span className="text-jade-600">(you)</span>}
                    </p>
                    <p className="text-xs text-ink-500">
                      {done ? "Received pot" : current ? "Receiving now" : "Upcoming"} ·{" "}
                      {m.payoutDate.toLocaleDateString("en-US", { month: "short", day: "numeric" })}
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

          <Card className="p-6">
            <h2 className="font-display text-lg font-bold text-ink-900">
              Your contribution history
            </h2>
            {circle.history.length === 0 ? (
              <p className="mt-4 text-sm text-ink-400">
                No contributions yet — this circle is still forming.
              </p>
            ) : (
              <ul className="mt-4 space-y-3">
                {circle.history.map((h) => (
                  <li
                    key={h.id}
                    className="flex items-center justify-between gap-2 border-b border-ink-900/[0.06] pb-3 last:border-0 last:pb-0"
                  >
                    <div>
                      <p className="text-sm font-semibold text-ink-900">
                        Round {h.round} · {formatMoney(h.amountCents)}
                      </p>
                      <p className="text-xs text-ink-500">
                        {h.createdAt.toLocaleDateString("en-US", {
                          month: "short",
                          day: "numeric",
                          year: "numeric",
                        })}
                      </p>
                    </div>
                    {h.txHash ? (
                      <TxTag hash={h.txHash} confirmed={h.status === "confirmed"} />
                    ) : (
                      <Badge tone="neutral">off-chain</Badge>
                    )}
                  </li>
                ))}
              </ul>
            )}
          </Card>
        </div>
      </div>
    </div>
  );
}
