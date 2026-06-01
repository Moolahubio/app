import { notFound } from "next/navigation";
import {
  Users,
  ShieldCheck,
  CheckCircle2,
  Circle as CircleIcon,
  CalendarClock,
  Crown,
} from "lucide-react";
import { Card, Button, Badge, Avatar, ProgressBar } from "@/components/ui";
import { BackLink, TxTag } from "@/components/app/bits";
import { circles } from "@/lib/data";
import { formatMoney, cn, truncateAddress } from "@/lib/utils";

export function generateStaticParams() {
  return circles.map((c) => ({ id: c.id }));
}

export default async function CircleDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const circle = circles.find((c) => c.id === id);
  if (!circle) notFound();

  const myPosition = circle.members.find((m) => m.isYou);

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
                {circle.frequency} · {circle.members.length} members · Round{" "}
                {circle.currentRound} of {circle.totalRounds}
              </p>
            </div>
          </div>
          <Badge tone="jade" className="bg-jade-500/15 text-jade-300 ring-jade-400/20 capitalize">
            {circle.status}
          </Badge>
        </div>

        <div className="mt-6 grid grid-cols-2 gap-4 sm:grid-cols-4">
          {[
            { label: "Per round", value: formatMoney(circle.contributionCents) },
            { label: "Pot payout", value: formatMoney(circle.potCents) },
            { label: "Your position", value: myPosition ? `#${myPosition.position}` : "—" },
            { label: "Next due", value: new Date(circle.nextContributionDate).toLocaleDateString("en-US", { month: "short", day: "numeric" }) },
          ].map((s) => (
            <div key={s.label}>
              <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-white/45">
                {s.label}
              </p>
              <p className="mt-1 font-display text-xl font-bold">{s.value}</p>
            </div>
          ))}
        </div>

        {circle.status === "active" && (
          <div className="mt-6 flex flex-wrap items-center gap-3">
            <Button size="sm">Contribute {formatMoney(circle.contributionCents)}</Button>
            <span className="inline-flex items-center gap-1.5 font-mono text-xs text-white/50">
              <ShieldCheck className="h-4 w-4 text-jade-400" />
              Contract {truncateAddress(circle.contractAddress, 6, 4)}
            </span>
          </div>
        )}
      </Card>

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
                    current
                      ? "border-jade-500/30 bg-jade-50"
                      : "border-ink-900/[0.06] bg-white",
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
                      {new Date(m.payoutDate).toLocaleDateString("en-US", { month: "short", day: "numeric" })}
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
              {circle.currentRound} of {circle.totalRounds} rounds complete
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
                        {new Date(h.date).toLocaleDateString("en-US", {
                          month: "short",
                          day: "numeric",
                          year: "numeric",
                        })}
                      </p>
                    </div>
                    <TxTag hash={h.txHash} confirmed={h.status === "confirmed"} />
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
