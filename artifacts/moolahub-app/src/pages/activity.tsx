import { ArrowDownLeft, ArrowUpRight, Sparkles, Target, Bell } from "lucide-react";
import { Card, Badge, IconChip } from "@/components/ui";
import { PageHeader, TxTag } from "@/components/app/bits";
import { useListActivity, useGetDashboardSummary } from "@workspace/api-client-react";
import type { ActivityItem } from "@workspace/api-client-react";
import { formatMoney } from "@/lib/utils";

const activityIcon: Record<string, typeof ArrowDownLeft> = {
  deposit: ArrowDownLeft,
  payout: ArrowDownLeft,
  yield: Sparkles,
  contribution: ArrowUpRight,
  goal_allocate: Target,
  goal_release: Target,
  withdrawal: ArrowUpRight,
};

const typeLabel: Record<string, string> = {
  deposit: "Deposit",
  payout: "Payout",
  yield: "Yield",
  contribution: "Contribution",
  goal_allocate: "Allocation",
  goal_release: "Release",
  withdrawal: "Withdrawal",
};

function groupByDay(items: ActivityItem[]) {
  const groups: Record<string, ActivityItem[]> = {};
  for (const item of items) {
    const key = new Date(item.createdAt).toLocaleDateString("en-US", {
      month: "long",
      day: "numeric",
      year: "numeric",
    });
    (groups[key] ??= []).push(item);
  }
  return Object.entries(groups);
}

export default function ActivityPage() {
  const { data: activity, isLoading: isActivityLoading } = useListActivity({ limit: 100 });
  const { data: summary } = useGetDashboardSummary();

  const grouped = groupByDay(activity ?? []);
  const reminder = summary?.upcomingReminder;

  if (isActivityLoading) return <div className="p-8 text-center text-ink-400">Loading activity...</div>;

  return (
    <div className="mx-auto max-w-5xl space-y-6">
      <PageHeader
        eyebrow="Activity"
        title="Your money, on the record"
        description="Every deposit, contribution and payout — each linked to its proof on Base."
      />

      {reminder && (
        <Card className="p-6">
          <div className="flex items-center gap-2">
            <Bell className="h-5 w-5 text-jade-600" />
            <h2 className="font-display text-lg font-bold text-ink-900">Upcoming reminders</h2>
          </div>
          <ul className="mt-4 grid gap-3 sm:grid-cols-3">
            <li className="rounded-2xl border border-ink-900/[0.06] bg-mist p-4">
              <div className="flex items-center justify-between">
                <Badge tone="amber" className="capitalize">
                  reminder
                </Badge>
                <span className="font-mono text-[10px] uppercase tracking-wide text-jade-600">
                  {new Date(reminder.dueDate).toLocaleDateString("en-US", { month: "short", day: "numeric" })}
                </span>
              </div>
              <p className="mt-3 text-sm font-semibold text-ink-900">{reminder.title}</p>
              <p className="mt-2 text-sm font-bold text-ink-900">{formatMoney(reminder.amountCents)}</p>
            </li>
          </ul>
        </Card>
      )}

      <Card className="p-6">
        <h2 className="font-display text-lg font-bold text-ink-900">Transaction history</h2>
        {grouped.length === 0 && (
          <p className="mt-4 text-sm text-ink-400">No transactions yet.</p>
        )}
        <div className="mt-4 space-y-6">
          {grouped.map(([day, items]) => (
            <div key={day}>
              <p className="font-mono text-[10px] uppercase tracking-[0.18em] text-ink-400">
                {day}
              </p>
              <ul className="mt-2 divide-y divide-ink-900/[0.06]">
                {items.map((item) => {
                  const Icon = activityIcon[item.type] ?? ArrowUpRight;
                  const positive = (item.amountCents ?? 0) > 0;
                  return (
                    <li key={item.id} className="flex items-center gap-4 py-3.5">
                      <IconChip tone={positive ? "jade" : "ink"} className="h-10 w-10">
                        <Icon className="h-5 w-5" />
                      </IconChip>
                      <div className="min-w-0 flex-1">
                        <p className="truncate text-sm font-semibold text-ink-900">
                          {item.description}
                        </p>
                        <div className="mt-0.5 flex flex-wrap items-center gap-2">
                          {item.txHash ? (
                            <TxTag hash={item.txHash} confirmed={item.onchainStatus !== "failed"} />
                          ) : (
                            <span className="font-mono text-[11px] text-ink-400">
                              {item.onchainStatus === "queued" ? "queued for chain" : "off-chain"}
                            </span>
                          )}
                        </div>
                      </div>
                      <div className="text-right">
                        {item.amountCents != null && (
                          <p
                            className={`text-sm font-semibold ${
                              positive ? "text-jade-600" : "text-ink-900"
                            }`}
                          >
                            {formatMoney(item.amountCents, { sign: true })}
                          </p>
                        )}
                        <p className="font-mono text-[10px] uppercase tracking-wide text-ink-400">
                          {typeLabel[item.type] ?? item.type}
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
