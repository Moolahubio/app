import { useState } from "react";
import { ArrowDownLeft, ArrowUpRight, Sparkles, Target, Bell, Receipt } from "lucide-react";
import { useTranslation } from "react-i18next";
import { GlassCard, IconChip, StatusPill, Skeleton, EmptyState } from "@/components/ui";
import { PageHeader, TxTag, Money } from "@/components/app/bits";
import { useListActivity, useGetDashboardSummary } from "@workspace/api-client-react";
import type { ActivityItem } from "@workspace/api-client-react";
import { formatDate, cn } from "@/lib/utils";

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

  const [activeTypes, setActiveTypes] = useState<string[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);

  const items = activity ?? [];
  const availableTypes = Array.from(new Set(items.map((i) => i.type)));
  const filtered = activeTypes.length === 0 ? items : items.filter((i) => activeTypes.includes(i.type));
  const grouped = groupByDay(filtered);
  const reminder = summary?.upcomingReminder;
  const selected = items.find((i) => i.id === selectedId) ?? filtered[0] ?? null;

  function toggleType(type: string) {
    setActiveTypes((prev) =>
      prev.includes(type) ? prev.filter((x) => x !== type) : [...prev, type],
    );
  }

  if (isActivityLoading) {
    return (
      <div className="mx-auto max-w-5xl space-y-6">
        <PageHeader
          eyebrow={t("common:nav.transactions")}
          title={t("header.title")}
          description={t("header.description")}
        />
        <Skeleton className="h-28 w-full" />
        <Skeleton className="h-96 w-full" />
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-5xl space-y-6">
      <PageHeader
        eyebrow={t("common:nav.transactions")}
        title={t("header.title")}
        description={t("header.description")}
      />

      {reminder && (
        <GlassCard>
          <div className="flex items-center gap-3">
            <IconChip tone="amber" className="h-9 w-9">
              <Bell className="h-5 w-5" />
            </IconChip>
            <h2 className="font-display text-lg font-bold text-[var(--mh-text-strong)]">
              {t("reminders.title")}
            </h2>
          </div>
          <div className="mt-4 rounded-2xl border border-[var(--mh-border)] p-4">
            <div className="flex items-center justify-between gap-2">
              <StatusPill tone="amber" className="capitalize">
                {t("reminders.tag")}
              </StatusPill>
              <span className="font-mono text-[10px] uppercase tracking-wide text-[var(--mh-mint)]">
                {formatDate(reminder.dueDate, { month: "short", day: "numeric" })}
              </span>
            </div>
            <p className="mt-3 text-sm font-semibold text-[var(--mh-text-strong)]">{reminder.title}</p>
            <p className="mt-2 font-display text-lg font-bold text-[var(--mh-text-strong)]">
              <Money cents={reminder.amountCents} />
            </p>
          </div>
        </GlassCard>
      )}

      <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_20rem]">
        <GlassCard className="min-w-0 overflow-hidden p-0">
          <div className="flex flex-wrap items-center justify-between gap-3 border-b border-[var(--mh-border)] p-5 md:p-6">
            <h2 className="font-display text-lg font-bold text-[var(--mh-text-strong)]">
              {t("history.title")}
            </h2>
            {availableTypes.length > 0 && (
              <div className="flex flex-wrap gap-2">
                {availableTypes.map((type) => {
                  const active = activeTypes.includes(type);
                  return (
                    <button
                      key={type}
                      type="button"
                      onClick={() => toggleType(type)}
                      aria-pressed={active}
                      className={cn(
                        "focus-ring rounded-full border px-3 py-1 text-xs font-semibold transition-colors",
                        active
                          ? "border-[rgba(45,212,166,0.24)] bg-[rgba(45,212,166,0.1)] text-[var(--mh-mint)]"
                          : "border-[var(--mh-border)] text-[var(--mh-muted)] hover:text-[var(--mh-text-strong)]",
                      )}
                    >
                      {t(`types.${type}`, { defaultValue: type })}
                    </button>
                  );
                })}
              </div>
            )}
          </div>

          <div className="p-5 md:p-6">
            {grouped.length === 0 ? (
              <EmptyState
                icon={<Receipt className="size-5" />}
                title={t("history.empty")}
                description={t("header.description")}
              />
            ) : (
              <div className="space-y-6">
                {grouped.map(([day, dayItems]) => (
                  <div key={day}>
                    <p className="mh-kicker mb-2">{day}</p>
                    <ul className="divide-y divide-[var(--mh-border)]">
                      {dayItems.map((item) => {
                        const Icon = activityIcon[item.type] ?? ArrowUpRight;
                        const positive = (item.amountCents ?? 0) > 0;
                        const isSelected = selected?.id === item.id;
                        return (
                          <li key={item.id}>
                            <button
                              type="button"
                              onClick={() => setSelectedId(item.id)}
                              className={cn(
                                "focus-ring flex w-full items-center gap-4 rounded-2xl px-2 py-3.5 text-start transition-colors hover:bg-[rgba(45,212,166,0.06)]",
                                isSelected && "bg-[rgba(45,212,166,0.08)]",
                              )}
                            >
                              <IconChip tone={positive ? "jade" : "ink"} className="h-10 w-10 shrink-0">
                                <Icon className="h-5 w-5" />
                              </IconChip>
                              <div className="min-w-0 flex-1">
                                <p className="truncate text-sm font-semibold text-[var(--mh-text-strong)]">
                                  {item.description}
                                </p>
                                <div className="mt-0.5 flex flex-wrap items-center gap-2">
                                  {item.txHash ? (
                                    <TxTag hash={item.txHash} confirmed={item.onchainStatus !== "failed"} />
                                  ) : (
                                    <span className="font-mono text-[11px] text-[var(--mh-muted)]">
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
                                    className={cn(
                                      "text-sm font-semibold",
                                      positive ? "text-[var(--mh-mint)]" : "text-[var(--mh-danger)]",
                                    )}
                                  >
                                    <Money cents={item.amountCents} sign />
                                  </p>
                                )}
                                <p className="font-mono text-[10px] uppercase tracking-wide text-[var(--mh-muted)]">
                                  {t(`types.${item.type}`, { defaultValue: item.type })}
                                </p>
                              </div>
                            </button>
                          </li>
                        );
                      })}
                    </ul>
                  </div>
                ))}
              </div>
            )}
          </div>
        </GlassCard>

        {selected && (
          <aside className="hidden lg:block">
            {(() => {
              const Icon = activityIcon[selected.type] ?? ArrowUpRight;
              const positive = (selected.amountCents ?? 0) > 0;
              return (
                <div className="mh-glass-strong sticky top-6 rounded-[var(--mh-radius-lg)] p-6">
                  <IconChip tone={positive ? "jade" : "ink"} className="h-12 w-12">
                    <Icon className="h-6 w-6" />
                  </IconChip>
                  <p className="mt-4 font-mono text-[10px] uppercase tracking-wide text-[var(--mh-muted)]">
                    {t(`types.${selected.type}`, { defaultValue: selected.type })}
                  </p>
                  <p className="mt-1 font-display text-lg font-bold text-[var(--mh-text-strong)]">
                    {selected.description}
                  </p>
                  {selected.amountCents != null && (
                    <p
                      className={cn(
                        "mt-4 font-display text-3xl font-semibold tracking-[-0.035em]",
                        positive ? "text-[var(--mh-mint)]" : "text-[var(--mh-danger)]",
                      )}
                    >
                      <Money cents={selected.amountCents} sign />
                    </p>
                  )}
                  <div className="mh-divider my-5" />
                  <p className="text-sm text-[var(--mh-muted)]">
                    {formatDate(selected.createdAt, { month: "long", day: "numeric", year: "numeric" })}
                  </p>
                  <div className="mt-3">
                    {selected.txHash ? (
                      <TxTag hash={selected.txHash} confirmed={selected.onchainStatus !== "failed"} />
                    ) : (
                      <span className="font-mono text-[11px] text-[var(--mh-muted)]">
                        {selected.onchainStatus === "pending" || selected.onchainStatus === "queued"
                          ? t("onchain.settling")
                          : t("onchain.offchain")}
                      </span>
                    )}
                  </div>
                </div>
              );
            })()}
          </aside>
        )}
      </div>
    </div>
  );
}
