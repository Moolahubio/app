import { Link, useRoute } from "wouter";
import { Plus, Repeat, Calendar, ArrowRight, Info } from "lucide-react";
import { Card, Button, Badge, ProgressBar } from "@/components/ui";
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

  if (goalsLoading || walletLoading) {
    return <div className="p-8 text-center text-muted-foreground">{t("list.loading")}</div>;
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
        action={
          <Dialog open={isCreateOpen} onOpenChange={setIsCreateOpen}>
            <DialogTrigger asChild>
              <Button>
                <Plus className="h-4 w-4" /> {t("list.newGoal")}
              </Button>
            </DialogTrigger>
            <DialogContent>
              <DialogHeader>
                <DialogTitle>{t("create.title")}</DialogTitle>
              </DialogHeader>
              <form onSubmit={handleCreate} className="space-y-4 pt-4">
                <div className="space-y-2">
                  <Label>{t("create.name.label")}</Label>
                  <Input value={name} onChange={e => setName(e.target.value)} required placeholder={t("create.name.placeholder")} />
                </div>
                <div className="space-y-2">
                  <Label>{t("create.target.label")}</Label>
                  <Input type="number" value={target} onChange={e => setTarget(e.target.value)} required placeholder="1000" />
                </div>
                <div className="space-y-2">
                  <Label>{t("create.deadline.label")}</Label>
                  <Input type="date" value={deadline} onChange={e => setDeadline(e.target.value)} required />
                </div>
                <div className="space-y-2">
                  <Label>{t("create.frequency.label")}</Label>
                  <Select value={frequency} onValueChange={(v) => setFrequency(asFrequency(v))}>
                    <SelectTrigger><SelectValue /></SelectTrigger>
                    <SelectContent>
                      {FREQUENCY_OPTIONS.map((o) => (
                        <SelectItem key={o.value} value={o.value}>{t(`cadence.option.${o.value}`)}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <p className="text-xs text-muted-foreground">
                    {t("create.frequency.hint")}
                  </p>
                </div>
                {previewPlan && (
                  <div className="rounded-xl border border-jade-500/15 bg-jade-50/50 p-4 dark:bg-jade-500/15">
                    <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-jade-700 dark:text-jade-300">
                      {t("create.plan.eyebrow")}
                    </p>
                    <p className="mt-1.5 text-sm text-foreground">
                      <Trans
                        t={t}
                        i18nKey={`create.plan.${frequency}`}
                        values={{ count: previewPlan.periods }}
                        components={[
                          <span className="font-semibold text-foreground">
                            <Money cents={previewPlan.firstCents} />
                          </span>,
                          <span className="font-semibold text-foreground">
                            <Money cents={previewPlan.lastCents} />
                          </span>,
                        ]}
                      />
                    </p>
                  </div>
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
        }
      />

      <div className="grid gap-4 sm:grid-cols-3">
        <Card className="p-5">
          <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-muted-foreground">
            {t("summary.allocated")}
          </p>
          <p className="mt-1 font-display text-2xl font-bold text-foreground">
            <Money cents={totalSaved} />
          </p>
        </Card>
        <Card className="p-5">
          <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-muted-foreground">
            {t("summary.combinedTarget")}
          </p>
          <p className="mt-1 font-display text-2xl font-bold text-foreground">
            <Money cents={totalTarget} />
          </p>
        </Card>
        <Card className="p-5">
          <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-muted-foreground">
            {t("summary.overallProgress")}
          </p>
          <p className="mt-1 font-display text-2xl font-bold text-jade-600 dark:text-jade-400">
            {pct(totalSaved, totalTarget)}%
          </p>
        </Card>
      </div>

      <div className="grid gap-5 md:grid-cols-2 lg:grid-cols-3">
        {goalsList.map((g) => {
          const gFreq = asFrequency(g.frequency);
          const gPlan = buildGoalPlan(g.targetCents, g.createdAt, g.deadline, gFreq);
          const gNext = nextContribution(gPlan.plan, g.savedCents);
          return (
          <Link key={g.id} href={`/goals/${g.id}`} className="group block">
            <Card className="h-full overflow-hidden p-0 transition-[border-color,background-color] duration-150 group-hover:border-jade-500/25">
              {g.imageUrl && (
                <div className="h-32 w-full overflow-hidden bg-background">
                  <img
                    src={avatarSrc(g.imageUrl)}
                    alt=""
                    className="h-full w-full object-cover transition-transform duration-200 group-hover:scale-[1.03]"
                  />
                </div>
              )}
              <div className="p-6">
              <div className="flex items-start justify-between">
                <span className="flex h-12 w-12 items-center justify-center rounded-2xl bg-background text-2xl">
                  {g.emoji || "🎯"}
                </span>
                {gNext && (
                  <Badge tone="jade">
                    <Repeat className="h-3 w-3" />{" "}
                    <Trans
                      t={t}
                      i18nKey="card.next"
                      values={{ unit: t(`cadence.short.${gFreq}`) }}
                      components={[<Money cents={gNext.amountCents} compact />]}
                    />
                  </Badge>
                )}
              </div>
              <h3 className="mt-4 font-display text-lg font-bold text-foreground">{g.name}</h3>
              <div className="mt-1 flex items-center gap-1.5 text-xs text-muted-foreground">
                <Calendar className="h-3.5 w-3.5" />
                {t("card.by", { date: formatDate(g.deadline, { month: "long", day: "numeric" }) })}
              </div>

              <div className="mt-5">
                <div className="flex items-end justify-between">
                  <p className="font-display text-xl font-bold text-foreground">
                    <Money cents={g.savedCents} />
                  </p>
                  <p className="text-sm text-muted-foreground">
                    <Trans t={t} i18nKey="card.of" components={[<Money cents={g.targetCents} />]} />
                  </p>
                </div>
                <ProgressBar value={g.savedCents} total={g.targetCents} className="mt-2" />
                <p className="mt-2 text-xs font-medium text-jade-600 dark:text-jade-400">
                  {t("card.pctThere", { pct: pct(g.savedCents, g.targetCents) })}
                </p>
              </div>

              <div className="mt-4 inline-flex items-center gap-1.5 text-sm font-medium text-jade-600 dark:text-jade-400">
                {t("card.manage")}{" "}
                <ArrowRight className="h-4 w-4 transition-transform group-hover:translate-x-0.5 rtl:rotate-180" />
              </div>
              </div>
            </Card>
          </Link>
          );
        })}

        <button
          onClick={() => setIsCreateOpen(true)}
          className="flex min-h-[280px] flex-col items-center justify-center gap-3 rounded-2xl border-2 border-dashed border-border p-6 text-muted-foreground transition-[color,border-color,transform] duration-150 hover:border-jade-500/35 hover:text-jade-600 dark:hover:text-jade-400 active:scale-[0.99] focus-ring"
        >
          <span className="flex h-12 w-12 items-center justify-center rounded-xl border border-border bg-card">
            <Plus className="h-6 w-6" />
          </span>
          <span className="text-sm font-semibold">{t("list.createGoal")}</span>
        </button>
      </div>

      <Card className="flex items-start gap-3 border-sky-500/15 bg-sky-50/50 p-5 dark:bg-sky-500/15">
        <Info className="mt-0.5 h-5 w-5 shrink-0 text-sky-600 dark:text-sky-400" />
        <p className="text-sm text-muted-foreground">
          <Trans
            t={t}
            i18nKey="info.unallocated"
            components={[
              <span className="font-semibold text-foreground">
                <Money cents={wallet?.availableCents ?? 0} />
              </span>,
            ]}
          />
        </p>
      </Card>
    </div>
  );
}
