import { Link, useRoute } from "wouter";
import { Plus, Repeat, Calendar, ArrowRight, Info, PiggyBank, Target, TrendingUp } from "lucide-react";
import { Button, MetricCard, GlassCard, GlassPanel, StatusPill, ProgressLine, Skeleton } from "@/components/ui";
import { PageHeader, Money } from "@/components/app/bits";
import { useListGoals, useGetWallet, useCreateGoal, getListGoalsQueryKey } from "@workspace/api-client-react";
import { pct, formatDate } from "@/lib/utils";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { ImageUploadField } from "@/components/app/ImageUploadField";
import { avatarSrc } from "@/lib/utils";
import {
  asFrequency,
  buildGoalPlan,
  nextContribution,
  FREQUENCY_OPTIONS,
  type Frequency,
} from "@/lib/contribution-plan";
import { useTranslation, Trans } from "react-i18next";
import { useState, useMemo } from "react";
import { useQueryClient } from "@tanstack/react-query";

export default function GoalsPage() {
  const { t } = useTranslation("goals");
  const { data: goals, isLoading: goalsLoading } = useListGoals();
  const { data: wallet, isLoading: walletLoading } = useGetWallet();
  const queryClient = useQueryClient();
  const createMutation = useCreateGoal();

  const [isNewRoute] = useRoute("/goals/new");
  const [isCreateOpen, setIsCreateOpen] = useState(!!isNewRoute);
  const [name, setName] = useState("");
  const [target, setTarget] = useState("");
  const [deadline, setDeadline] = useState("");
  const [frequency, setFrequency] = useState<Frequency>("weekly");
  const [imageUrl, setImageUrl] = useState<string | null>(null);

  const previewPlan = useMemo(() => {
    const targetCents = Math.floor(parseFloat(target) * 100);
    if (!Number.isFinite(targetCents) || targetCents <= 0 || !deadline) return null;
    const deadlineDate = new Date(deadline);
    if (Number.isNaN(deadlineDate.getTime()) || deadlineDate <= new Date()) return null;
    return buildGoalPlan(targetCents, new Date(), deadlineDate, frequency);
  }, [target, deadline, frequency]);

  const handleCreate = (e: React.FormEvent) => {
    e.preventDefault();
    createMutation.mutate(
      { 
        data: { 
          name, 
          targetCents: Math.floor(parseFloat(target) * 100), 
          deadline: new Date(deadline).toISOString(),
          frequency,
          imageUrl: imageUrl ?? undefined,
        } 
      },
      {
        onSuccess: () => {
          queryClient.invalidateQueries({ queryKey: getListGoalsQueryKey() });
          setIsCreateOpen(false);
          setName("");
          setTarget("");
          setDeadline("");
          setFrequency("weekly");
          setImageUrl(null);
        }
      }
    );
  };

  const createDialog = (
    <Dialog open={isCreateOpen} onOpenChange={setIsCreateOpen}>
      <DialogTrigger asChild>
        <Button>
          <Plus className="h-4 w-4" /> {t("list.newGoal")}
        </Button>
      </DialogTrigger>
      <DialogContent className="mh-glass-strong border-[var(--mh-border)]">
        <DialogHeader>
          <DialogTitle className="font-display text-xl font-bold text-[var(--mh-text-strong)]">
            {t("create.title")}
          </DialogTitle>
        </DialogHeader>
        <form onSubmit={handleCreate} className="space-y-4 pt-2">
          <div className="space-y-2">
            <Label>{t("create.name.label")}</Label>
            <Input className="mh-input" value={name} onChange={e => setName(e.target.value)} required placeholder={t("create.name.placeholder")} />
          </div>
          <div className="space-y-2">
            <Label>{t("create.target.label")}</Label>
            <Input className="mh-input" type="number" value={target} onChange={e => setTarget(e.target.value)} required placeholder="1000" />
          </div>
          <div className="space-y-2">
            <Label>{t("create.deadline.label")}</Label>
            <Input className="mh-input" type="date" value={deadline} onChange={e => setDeadline(e.target.value)} required />
          </div>
          <div className="space-y-2">
            <Label>{t("create.frequency.label")}</Label>
            <Select value={frequency} onValueChange={(v) => setFrequency(asFrequency(v))}>
              <SelectTrigger className="mh-input"><SelectValue /></SelectTrigger>
              <SelectContent>
                {FREQUENCY_OPTIONS.map((o) => (
                  <SelectItem key={o.value} value={o.value}>{t(`cadence.option.${o.value}`)}</SelectItem>
                ))}
              </SelectContent>
            </Select>
            <p className="text-xs text-[var(--mh-muted)]">
              {t("create.frequency.hint")}
            </p>
          </div>
          {previewPlan && (
            <GlassPanel className="border-[rgba(45,212,166,0.24)] bg-[rgba(45,212,166,0.08)] p-4">
              <p className="mh-kicker">
                {t("create.plan.eyebrow")}
              </p>
              <p className="mt-1.5 text-sm text-[var(--mh-text-strong)]">
                <Trans
                  t={t}
                  i18nKey={`create.plan.${frequency}`}
                  values={{ count: previewPlan.periods }}
                  components={[
                    <span className="font-semibold text-[var(--mh-text-strong)]">
                      <Money cents={previewPlan.firstCents} />
                    </span>,
                    <span className="font-semibold text-[var(--mh-text-strong)]">
                      <Money cents={previewPlan.lastCents} />
                    </span>,
                  ]}
                />
              </p>
            </GlassPanel>
          )}
          <ImageUploadField
            label={t("create.image.label")}
            hint={t("create.image.hint")}
            value={imageUrl}
            onChange={setImageUrl}
          />
          <Button type="submit" className="w-full" disabled={createMutation.isPending}>
            {createMutation.isPending ? t("create.submitting") : t("create.submit")}
          </Button>
        </form>
      </DialogContent>
    </Dialog>
  );

  if (goalsLoading || walletLoading) {
    return (
      <div className="mx-auto max-w-6xl space-y-6">
        <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
          <div className="space-y-2">
            <Skeleton className="h-3 w-32" />
            <Skeleton className="h-9 w-64" />
          </div>
          <Skeleton className="h-11 w-32" />
        </div>
        <div className="grid gap-4 sm:grid-cols-3">
          {Array.from({ length: 3 }).map((_, i) => (
            <Skeleton key={i} className="h-28" />
          ))}
        </div>
        <div className="grid gap-5 md:grid-cols-2 lg:grid-cols-3">
          {Array.from({ length: 3 }).map((_, i) => (
            <Skeleton key={i} className="h-72" />
          ))}
        </div>
      </div>
    );
  }

  const goalsList = goals ?? [];
  const totalTarget = goalsList.reduce((s, g) => s + g.targetCents, 0);
  const totalSaved = goalsList.reduce((s, g) => s + g.savedCents, 0);

  return (
    <div className="mx-auto max-w-6xl space-y-6">
      <PageHeader
        eyebrow={t("common:nav.personalSavings")}
        title={t("list.title")}
        description={t("list.description")}
        action={createDialog}
      />

      <div className="grid gap-4 sm:grid-cols-3">
        <MetricCard
          label={t("summary.allocated")}
          value={<Money cents={totalSaved} />}
          icon={<PiggyBank className="h-5 w-5" />}
        />
        <MetricCard
          label={t("summary.combinedTarget")}
          value={<Money cents={totalTarget} />}
          icon={<Target className="h-5 w-5" />}
        />
        <MetricCard
          label={t("summary.overallProgress")}
          value={`${pct(totalSaved, totalTarget)}%`}
          icon={<TrendingUp className="h-5 w-5" />}
        />
      </div>

      <div className="grid gap-5 md:grid-cols-2 lg:grid-cols-3">
        {goalsList.map((g) => {
          const gFreq = asFrequency(g.frequency);
          const gPlan = buildGoalPlan(g.targetCents, g.createdAt, g.deadline, gFreq);
          const gNext = nextContribution(gPlan.plan, g.savedCents);
          const gPct = pct(g.savedCents, g.targetCents);
          return (
          <Link key={g.id} href={`/goals/${g.id}`} className="group block">
            <GlassCard hover className="h-full overflow-hidden p-0">
              {g.imageUrl && (
                <div className="h-32 w-full overflow-hidden bg-[var(--mh-track)]">
                  <img
                    src={avatarSrc(g.imageUrl)}
                    alt=""
                    className="h-full w-full object-cover transition-transform duration-200 group-hover:scale-[1.03]"
                  />
                </div>
              )}
              <div className="p-6">
              <div className="flex items-start justify-between gap-3">
                <span className="flex h-12 w-12 items-center justify-center rounded-2xl border border-[var(--mh-border)] bg-[rgba(45,212,166,0.09)] text-2xl">
                  {g.emoji || "🎯"}
                </span>
                {gNext && (
                  <StatusPill tone="jade">
                    <Repeat className="h-3 w-3" />{" "}
                    <Trans
                      t={t}
                      i18nKey="card.next"
                      values={{ unit: t(`cadence.short.${gFreq}`) }}
                      components={[<Money cents={gNext.amountCents} compact />]}
                    />
                  </StatusPill>
                )}
              </div>
              <h3 className="mt-4 font-display text-lg font-bold text-[var(--mh-text-strong)]">{g.name}</h3>
              <div className="mt-1 flex items-center gap-1.5 text-xs text-[var(--mh-muted)]">
                <Calendar className="h-3.5 w-3.5" />
                {t("card.by", { date: formatDate(g.deadline, { month: "long", day: "numeric" }) })}
              </div>

              <div className="mt-5">
                <div className="flex items-end justify-between gap-2">
                  <p className="font-display text-xl font-bold text-[var(--mh-text-strong)]">
                    <Money cents={g.savedCents} />
                  </p>
                  <p className="text-sm text-[var(--mh-muted)]">
                    <Trans t={t} i18nKey="card.of" components={[<Money cents={g.targetCents} />]} />
                  </p>
                </div>
                <ProgressLine value={gPct} className="mt-2" />
                <p className="mt-2 text-xs font-semibold text-[var(--mh-mint)]">
                  {t("card.pctThere", { pct: gPct })}
                </p>
              </div>

              <div className="mt-4 inline-flex items-center gap-1.5 text-sm font-semibold text-[var(--mh-mint)]">
                {t("card.manage")}{" "}
                <ArrowRight className="h-4 w-4 transition-transform group-hover:translate-x-0.5 rtl:rotate-180" />
              </div>
              </div>
            </GlassCard>
          </Link>
          );
        })}

        <button
          onClick={() => setIsCreateOpen(true)}
          className="focus-ring flex min-h-[280px] flex-col items-center justify-center gap-3 rounded-[var(--mh-radius-lg)] border-2 border-dashed border-[var(--mh-border)] p-6 text-[var(--mh-muted)] transition-[color,border-color,transform] duration-150 hover:border-[rgba(45,212,166,0.4)] hover:text-[var(--mh-mint)] active:scale-[0.99]"
        >
          <span className="flex h-12 w-12 items-center justify-center rounded-2xl border border-[var(--mh-border)] bg-[rgba(45,212,166,0.09)]">
            <Plus className="h-6 w-6" />
          </span>
          <span className="text-sm font-semibold">{t("list.createGoal")}</span>
        </button>
      </div>

      <GlassCard className="flex items-start gap-3">
        <span className="grid size-10 shrink-0 place-items-center rounded-2xl border border-[rgba(56,189,248,0.24)] bg-[rgba(56,189,248,0.1)] text-sky-500">
          <Info className="h-5 w-5" />
        </span>
        <p className="text-sm text-[var(--mh-muted)]">
          <Trans
            t={t}
            i18nKey="info.unallocated"
            components={[
              <span className="font-semibold text-[var(--mh-text-strong)]">
                <Money cents={wallet?.availableCents ?? 0} />
              </span>,
            ]}
          />
        </p>
      </GlassCard>
    </div>
  );
}
