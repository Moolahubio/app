import Link from "next/link";
import { Plus, Users, ArrowRight, ShieldCheck, Inbox } from "lucide-react";
import { Card, Button, Badge, ProgressBar, Avatar, Eyebrow } from "@/components/ui";
import { PageHeader } from "@/components/app/bits";
import { ActionButton } from "@/components/app/forms";
import { requireUser } from "@/lib/server/auth";
import { listCirclesForUser, listInvitesForUser } from "@/lib/server/circles";
import { acceptInviteAction, declineInviteAction } from "@/app/(app)/actions";
import { formatMoney } from "@/lib/utils";

const statusTone = {
  active: "jade",
  forming: "amber",
  completed: "neutral",
} as const;

export default async function CirclesPage() {
  const user = await requireUser();
  const [circles, invites] = await Promise.all([
    listCirclesForUser(user.id),
    listInvitesForUser(user.email),
  ]);
  const visible = circles.filter((c) => c.status !== "completed");

  return (
    <div className="mx-auto max-w-6xl space-y-6">
      <PageHeader
        eyebrow="Susu Circles"
        title="Your circles"
        description="Rotating savings with people you trust — every round held by an audited on-chain contract, not a person."
        action={
          <Button href="/circles/new">
            <Plus className="h-4 w-4" /> Start a circle
          </Button>
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

      {invites.length > 0 && (
        <Card className="border-jade-500/20 bg-jade-50/50 p-6">
          <div className="flex items-center gap-2">
            <Inbox className="h-5 w-5 text-jade-600" />
            <h2 className="font-display text-lg font-bold text-ink-900">
              Invitations ({invites.length})
            </h2>
          </div>
          <ul className="mt-4 space-y-3">
            {invites.map((inv) => (
              <li
                key={inv.id}
                className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-ink-900/[0.06] bg-white p-4"
              >
                <div>
                  <p className="font-semibold text-ink-900">{inv.circleName}</p>
                  <p className="text-xs text-ink-500">
                    {inv.invitedBy} invited you · {formatMoney(inv.contributionCents)}/{inv.frequency} ·{" "}
                    {inv.memberCount} members
                  </p>
                </div>
                <div className="flex items-center gap-2">
                  <ActionButton
                    action={acceptInviteAction}
                    hidden={{ inviteId: inv.id }}
                    label="Accept"
                    pendingLabel="…"
                    size="sm"
                  />
                  <ActionButton
                    action={declineInviteAction}
                    hidden={{ inviteId: inv.id }}
                    label="Decline"
                    pendingLabel="…"
                    size="sm"
                    variant="secondary"
                  />
                </div>
              </li>
            ))}
          </ul>
        </Card>
      )}

      <div className="grid gap-5 md:grid-cols-2">
        {visible.map((circle) => (
          <Link key={circle.id} href={`/circles/${circle.id}`} className="group">
            <Card className="h-full p-6 transition-all group-hover:-translate-y-1 group-hover:shadow-card-hover">
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
                <Badge tone={statusTone[circle.status as keyof typeof statusTone]} className="capitalize">
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
                    <span>{circle.paidOutCount} paid out</span>
                  </div>
                  <ProgressBar value={circle.currentRound} total={circle.totalRounds} className="mt-2" />
                </div>
              ) : (
                <div className="mt-5 flex items-center gap-2">
                  <div className="flex -space-x-2">
                    {circle.members.map((m) => (
                      <Avatar
                        key={m.name}
                        name={m.name}
                        tone={m.isYou ? "jade" : "ink"}
                        className="h-8 w-8 ring-2 ring-white"
                      />
                    ))}
                  </div>
                  <span className="text-xs text-ink-500">Forming — invite to fill the circle</span>
                </div>
              )}

              <div className="mt-5 inline-flex items-center gap-1.5 text-sm font-medium text-jade-600">
                View circle{" "}
                <ArrowRight className="h-4 w-4 transition-transform group-hover:translate-x-0.5" />
              </div>
            </Card>
          </Link>
        ))}

        <Link
          href="/circles/new"
          className="flex min-h-[230px] flex-col items-center justify-center gap-3 rounded-3xl border-2 border-dashed border-ink-900/15 p-6 text-ink-400 transition-colors hover:border-jade-500/40 hover:text-jade-600 focus-ring"
        >
          <span className="flex h-12 w-12 items-center justify-center rounded-2xl bg-white shadow-card">
            <Plus className="h-6 w-6" />
          </span>
          <span className="text-sm font-semibold">Start a new circle</span>
          <span className="max-w-[200px] text-center text-xs">
            Invite friends or family and set your contribution
          </span>
        </Link>
      </div>

      <Eyebrow className="pt-4 text-center text-ink-300">Save Now · Grow Together</Eyebrow>
    </div>
  );
}
