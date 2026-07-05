import { ArrowDownLeft, ArrowUpRight, Sparkles, Target, Bell } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Card, Badge, IconChip } from "@/components/ui";
import { PageHeader, TxTag, Money } from "@/components/app/bits";
import { useListActivity, useGetDashboardSummary } from "@workspace/api-client-react";
import type { ActivityItem } from "@workspace/api-client-react";
import { formatDate } from "@/lib/utils";

const activityIcon: Record<string, typeof ArrowDownLeft> = {
  deposit: ArrowDownLeft,
  payout: ArrowDownLeft,
  yield: Sparkles,
  contribution: ArrowUpRight,
  goal_allocate: Target,
  goal_release: Target,
  withdrawal: ArrowUpRight,
};

function groupByDay(items: ActivityItem[]) {
  const groups: Record<string, ActivityItem[]> = {};
  for (const item of items) {
    const key = formatDate(item.createdAt, {
      month: "long",
      day: "numeric",
      year: "numeric",
    });
    (groups[key] ??= []).push(item);
  }
  return Object.entries(groups);
}

export default function TransactionsPage() {
  const { t } = useTranslation("transactions");
  const { data: activity, isLoading: isActivityLoading } = useListActivity({ limit: 100 });
  const { data: summary } = useGetDashboardSummary();

  const grouped = groupByDay(activity ?? []);
  const reminder = summary?.upcomingReminder;

  if (isActivityLoading) return <div className="p-8 text-center text-muted-foreground">{t("loading")}</div>;

  return (
    <div className="mx-auto max-w-5xl space-y-6">
      <PageHeader
        eyebrow={t("common:nav.transactions")}
        title={t("header.title")}
        description={t("header.description")}
      />

      {reminder && (
        <Card className="p-6">
          <div className="flex items-center gap-2">
            <Bell className="h-5 w-5 text-jade-600 dark:text-jade-400" />
            <h2 className="font-display text-lg font-bold text-foreground">{t("reminders.title")}</h2>
          </div>
          <ul className="mt-4 grid gap-3 sm:grid-cols-3">
            <li className="rounded-2xl border border-border bg-background p-4">
              <div className="flex items-center justify-between">
                <Badge tone="amber" className="capitalize">
                  {t("reminders.tag")}
                </Badge>
                <span className="font-mono text-[10px] uppercase tracking-wide text-jade-600 dark:text-jade-400">
                  {formatDate(reminder.dueDate, { month: "short", day: "numeric" })}
                </span>
              </div>
              <p className="mt-3 text-sm font-semibold text-foreground">{reminder.title}</p>
              <p className="mt-2 text-sm font-bold text-foreground">
                <Money cents={reminder.amountCents} />
              </p>
            </li>
          </ul>
        </Card>
      )}

      <Card className="p-6">
        <h2 className="font-display text-lg font-bold text-foreground">{t("history.title")}</h2>
        {grouped.length === 0 && (
          <p className="mt-4 text-sm text-muted-foreground">{t("history.empty")}</p>
        )}
        <div className="mt-4 space-y-6">
          {grouped.map(([day, items]) => (
            <div key={day}>
              <p className="font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
                {day}
              </p>
              <ul className="mt-2 divide-y divide-border">
                {items.map((item) => {
                  const Icon = activityIcon[item.type] ?? ArrowUpRight;
                  const positive = (item.amountCents ?? 0) > 0;
                  return (
                    <li key={item.id} className="flex items-center gap-4 py-3.5">
                      <IconChip tone={positive ? "jade" : "ink"} className="h-10 w-10">
                        <Icon className="h-5 w-5" />
                      </IconChip>
                      <div className="min-w-0 flex-1">
                        <p className="truncate text-sm font-semibold text-foreground">
                          {item.description}
                        </p>
                        <div className="mt-0.5 flex flex-wrap items-center gap-2">
                          {item.txHash ? (
                            <TxTag hash={item.txHash} confirmed={item.onchainStatus !== "failed"} />
                          ) : (
                            <span className="font-mono text-[11px] text-muted-foreground">
                              {item.onchainStatus === "pending" || item.onchainStatus === "queued"
                                ? t("onchain.settling")
                                : t("onchain.offchain")}
                            </span>
                          )}
                        </div>
                      </div>
                      <div className="text-end">
                        {item.amountCents != null && (
                          <p
                            className={`text-sm font-semibold ${
                              positive ? "text-jade-600 dark:text-jade-400" : "text-foreground"
                            }`}
                          >
                            <Money cents={item.amountCents} sign />
                          </p>
                        )}
                        <p className="font-mono text-[10px] uppercase tracking-wide text-muted-foreground">
                          {t(`types.${item.type}`, { defaultValue: item.type })}
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
