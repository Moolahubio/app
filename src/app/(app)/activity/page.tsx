import {
  ArrowDownLeft,
  ArrowUpRight,
  Sparkles,
  Target,
  Bell,
} from "lucide-react";
import { Card, Badge, IconChip } from "@/components/ui";
import { PageHeader, TxTag } from "@/components/app/bits";
import { activity, reminders } from "@/lib/data";
import { formatMoney } from "@/lib/utils";

const activityIcon = {
  deposit: ArrowDownLeft,
  payout: ArrowDownLeft,
  yield: Sparkles,
  contribution: ArrowUpRight,
  goal: Target,
  withdrawal: ArrowUpRight,
} as const;

const typeLabel = {
  deposit: "Deposit",
  payout: "Payout",
  yield: "Yield",
  contribution: "Contribution",
  goal: "Goal",
  withdrawal: "Withdrawal",
} as const;

/** Group activity by calendar day for a clean ledger view. */
function groupByDay(items: typeof activity) {
  const groups: Record<string, typeof activity> = {};
  for (const item of items) {
    const key = new Date(item.date).toLocaleDateString("en-US", {
      month: "long",
      day: "numeric",
      year: "numeric",
    });
    (groups[key] ??= []).push(item);
  }
  return Object.entries(groups);
}

export default function ActivityPage() {
  const grouped = groupByDay(activity);

  return (
    <div className="mx-auto max-w-5xl space-y-6">
      <PageHeader
        eyebrow="Activity"
        title="Your money, on the record"
        description="Every deposit, contribution and payout — each linked to its proof on the Stellar ledger."
      />

      {/* upcoming reminders */}
      <Card className="p-6">
        <div className="flex items-center gap-2">
          <Bell className="h-5 w-5 text-jade-600" />
          <h2 className="font-display text-lg font-bold text-ink-900">Upcoming reminders</h2>
        </div>
        <ul className="mt-4 grid gap-3 sm:grid-cols-3">
          {reminders.map((r) => (
            <li key={r.id} className="rounded-2xl border border-ink-900/[0.06] bg-mist p-4">
              <div className="flex items-center justify-between">
                <Badge tone="amber" className="capitalize">
                  {r.kind}
                </Badge>
                <span className="font-mono text-[10px] uppercase tracking-wide text-jade-600">
                  {new Date(r.dueDate).toLocaleDateString("en-US", { month: "short", day: "numeric" })}
                </span>
              </div>
              <p className="mt-3 text-sm font-semibold text-ink-900">{r.title}</p>
              <p className="text-xs text-ink-500">{r.detail}</p>
              <p className="mt-2 text-sm font-bold text-ink-900">{formatMoney(r.amountCents)}</p>
            </li>
          ))}
        </ul>
      </Card>

      {/* ledger */}
      <Card className="p-6">
        <h2 className="font-display text-lg font-bold text-ink-900">Transaction history</h2>
        <div className="mt-4 space-y-6">
          {grouped.map(([day, items]) => (
            <div key={day}>
              <p className="font-mono text-[10px] uppercase tracking-[0.18em] text-ink-400">
                {day}
              </p>
              <ul className="mt-2 divide-y divide-ink-900/[0.06]">
                {items.map((item) => {
                  const Icon = activityIcon[item.type];
                  const positive = item.amountCents > 0;
                  return (
                    <li key={item.id} className="flex items-center gap-4 py-3.5">
                      <IconChip tone={positive ? "jade" : "ink"} className="h-10 w-10">
                        <Icon className="h-5 w-5" />
                      </IconChip>
                      <div className="min-w-0 flex-1">
                        <p className="truncate text-sm font-semibold text-ink-900">{item.title}</p>
                        <div className="mt-0.5 flex flex-wrap items-center gap-2">
                          <span className="truncate text-xs text-ink-500">{item.subtitle}</span>
                          {item.txHash && <TxTag hash={item.txHash} />}
                        </div>
                      </div>
                      <div className="text-right">
                        <p
                          className={`text-sm font-semibold ${
                            positive ? "text-jade-600" : "text-ink-900"
                          }`}
                        >
                          {formatMoney(item.amountCents, { sign: true })}
                        </p>
                        <p className="font-mono text-[10px] uppercase tracking-wide text-ink-400">
                          {typeLabel[item.type]}
                        </p>
                      </div>
                    </li>
                  );
                })}
              </ul>
            </div>
          ))}
        </div>
      </Card>
    </div>
  );
}
