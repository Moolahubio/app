import { Link } from "wouter";
import { Plus, Users, ArrowRight, ShieldCheck, Inbox, Repeat, Coins } from "lucide-react";
import { Button, Badge, Eyebrow, Skeleton, GlassCard, MetricCard, StatusPill, ProgressLine } from "@/components/ui";
import { PageHeader, Money } from "@/components/app/bits";
import { ActionButton } from "@/components/app/forms";
import { useListCircles, useListInvites, useAcceptInvite, useDeclineInvite, useCreateCircle, getListCirclesQueryKey, getListInvitesQueryKey } from "@workspace/api-client-react";
import { formatMoney, pct } from "@/lib/utils";
import { useQueryClient } from "@tanstack/react-query";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import { ImageUploadField } from "@/components/app/ImageUploadField";
import { avatarSrc, cn } from "@/lib/utils";
import { useTranslation, Trans } from "react-i18next";
import { useState } from "react";

const statusTone: Record<string, "jade" | "amber" | "neutral"> = {
  active: "jade",
  forming: "amber",
  completed: "neutral",
};

export default function CirclesPage() {
  const { t } = useTranslation("circles");
  const { data: circles, isLoading: circlesLoading } = useListCircles();
  const { data: invites, isLoading: invitesLoading } = useListInvites();
  
  const queryClient = useQueryClient();
  const acceptMutation = useAcceptInvite();
  const declineMutation = useDeclineInvite();
  const createMutation = useCreateCircle();

  const [isCreateOpen, setIsCreateOpen] = useState(false);
  const [name, setName] = useState("");
  const [type, setType] = useState<"rotation" | "accumulation">("rotation");
  const [contribution, setContribution] = useState("");
  const [numRounds, setNumRounds] = useState("6");
  const [targetPayout, setTargetPayout] = useState("");
  const [groupSize, setGroupSize] = useState("4");
  const [frequency, setFrequency] = useState("weekly");
  const [emails, setEmails] = useState("");
  const [imageUrl, setImageUrl] = useState<string | null>(null);

  const FEE_RATE = 0.02; // 2% added on top of each member's base contribution
  const emailCount = emails.split(",").map((e) => e.trim()).filter(Boolean).length;

  // Rotation (target-payout): owner sets the payout each member receives and the
  // group size; everyone pays an equal base + 2% fee so the recipient nets the target.
  const targetNum = parseFloat(targetPayout) || 0;
  const groupNum = Math.max(0, parseInt(groupSize, 10) || 0);
  const baseCents = type === "rotation" && groupNum >= 1 ? Math.round((targetNum * 100) / groupNum) : 0;
  const perPersonCents = baseCents + Math.round(baseCents * FEE_RATE);
  const rotationFeeCents = perPersonCents - baseCents;
  const rotationReceiveCents = baseCents * groupNum;

  // Accumulation: fixed contribution; get your own savings back at the end.
  const contributionAmount = parseFloat(contribution) || 0;
  const roundsNum = Math.max(0, parseInt(numRounds, 10) || 0);

  const maxInvites = type === "rotation" ? Math.max(0, groupNum - 1) : 19;
  const payPerRoundCents = type === "rotation" ? perPersonCents : Math.round(contributionAmount * 100);
  const receiveCents = type === "rotation" ? rotationReceiveCents : Math.round(contributionAmount * 100) * roundsNum;
  const rotationInvalid = type === "rotation" && (targetNum <= 0 || groupNum < 2);

  const handleCreate = (e: React.FormEvent) => {
    e.preventDefault();
    const memberEmails = emails.split(",").map((s) => s.trim()).filter(Boolean);
    const data =
      type === "rotation"
        ? {
            name,
            type,
            targetPayoutCents: Math.round(targetNum * 100),
            groupSize: groupNum,
            frequency,
            memberEmails,
            imageUrl: imageUrl ?? undefined,
          }
        : {
            name,
            type,
            contributionCents: Math.round(contributionAmount * 100),
            numRounds: roundsNum,
            frequency,
            memberEmails,
            imageUrl: imageUrl ?? undefined,
          };
    createMutation.mutate(
      { data },
      {
        onSuccess: () => {
          queryClient.invalidateQueries({ queryKey: getListCirclesQueryKey() });
          setIsCreateOpen(false);
          setName("");
          setType("rotation");
          setContribution("");
          setNumRounds("6");
          setTargetPayout("");
          setGroupSize("4");
          setEmails("");
          setImageUrl(null);
        }
      }
    );
  };

  if (circlesLoading || invitesLoading) {
    return (
      <div className="mx-auto max-w-6xl space-y-6">
        <span className="sr-only">{t("list.loading")}</span>
        <Skeleton className="h-24 w-full" />
        <div className="grid gap-4 sm:grid-cols-3">
          <Skeleton className="h-28" />
          <Skeleton className="h-28" />
          <Skeleton className="h-28" />
        </div>
        <div className="grid gap-5 md:grid-cols-2">
          <Skeleton className="h-64" />
          <Skeleton className="h-64" />
        </div>
      </div>
    );
  }

  const visible = circles?.filter((c) => c.status !== "completed") ?? [];
  const inviteList = invites ?? [];

  const activeCount = visible.filter((c) => c.status === "active").length;
  const totalPerRound = visible.reduce((s, c) => s + (c.contributionCents ?? 0), 0);
  const totalPayout = visible.reduce((s, c) => s + (c.payoutCents ?? 0), 0);

  return (
    <div className="mx-auto max-w-6xl space-y-6">
      <PageHeader
        eyebrow={t("common:nav.groupSavings")}
        title={t("list.title")}
        description={t("list.description")}
        action={
          <Dialog open={isCreateOpen} onOpenChange={setIsCreateOpen}>
            <DialogTrigger asChild>
              <Button>
                <Plus className="h-4 w-4" /> {t("create.startCircle")}
              </Button>
            </DialogTrigger>
            <DialogContent className="mh-glass-strong border-white/10">
              <DialogHeader>
                <DialogTitle>{t("create.title")}</DialogTitle>
              </DialogHeader>
              <form onSubmit={handleCreate} className="space-y-4 pt-4">
                <div className="space-y-2">
                  <Label>{t("create.name.label")}</Label>
                  <Input className="mh-input" value={name} onChange={e => setName(e.target.value)} required placeholder={t("create.name.placeholder")} />
                </div>
                <div className="space-y-2">
                  <Label>{t("create.type.label")}</Label>
                  <RadioGroup
                    value={type}
                    onValueChange={(v) => setType(v as "rotation" | "accumulation")}
                    className="gap-2"
                  >
                    <label
                      htmlFor="type-rotation"
                      className={cn(
                        "flex cursor-pointer items-start gap-3 rounded-2xl border p-3 transition-colors",
                        type === "rotation" ? "border-jade-500/40 bg-jade-50/60 dark:bg-jade-500/15" : "border-border",
                      )}
                    >
                      <RadioGroupItem value="rotation" id="type-rotation" className="mt-0.5" />
                      <span className="text-sm">
                        <span className="font-semibold text-foreground">{t("create.type.rotation.title")}</span>
                        <span className="block text-xs text-muted-foreground">
                          {t("create.type.rotation.description")}
                        </span>
                      </span>
                    </label>
                    <label
                      htmlFor="type-accumulation"
                      className={cn(
                        "flex cursor-pointer items-start gap-3 rounded-2xl border p-3 transition-colors",
                        type === "accumulation" ? "border-jade-500/40 bg-jade-50/60 dark:bg-jade-500/15" : "border-border",
                      )}
                    >
                      <RadioGroupItem value="accumulation" id="type-accumulation" className="mt-0.5" />
                      <span className="text-sm">
                        <span className="font-semibold text-foreground">{t("create.type.accumulation.title")}</span>
                        <span className="block text-xs text-muted-foreground">
                          {t("create.type.accumulation.description")}
                        </span>
                      </span>
                    </label>
                  </RadioGroup>
                </div>
                {type === "rotation" ? (
                  <>
                    <div className="space-y-2">
                      <Label>{t("create.targetPayout.label")}</Label>
                      <Input
                        className="mh-input"
                        type="number"
                        min={1}
                        value={targetPayout}
                        onChange={(e) => setTargetPayout(e.target.value)}
                        required
                        placeholder="20000"
                      />
                      <p className="text-xs text-muted-foreground">
                        {t("create.targetPayout.hint")}
                      </p>
                    </div>
                    <div className="space-y-2">
                      <Label>{t("create.groupSize.label")}</Label>
                      <Input
                        className="mh-input"
                        type="number"
                        min={2}
                        max={20}
                        value={groupSize}
                        onChange={(e) => setGroupSize(e.target.value)}
                        required
                        placeholder="4"
                      />
                    </div>
                  </>
                ) : (
                  <>
                    <div className="space-y-2">
                      <Label>{t("create.contribution.label")}</Label>
                      <Input className="mh-input" type="number" value={contribution} onChange={e => setContribution(e.target.value)} required placeholder="100" />
                    </div>
                    <div className="space-y-2">
                      <Label>{t("create.numRounds.label")}</Label>
                      <Input
                        className="mh-input"
                        type="number"
                        min={2}
                        value={numRounds}
                        onChange={(e) => setNumRounds(e.target.value)}
                        required
                        placeholder="6"
                      />
                    </div>
                  </>
                )}
                <div className="space-y-2">
                  <Label>{t("create.frequency.label")}</Label>
                  <Select value={frequency} onValueChange={setFrequency}>
                    <SelectTrigger><SelectValue /></SelectTrigger>
                    <SelectContent>
                      <SelectItem value="weekly">{t("frequency.weekly")}</SelectItem>
                      <SelectItem value="biweekly">{t("frequency.biweekly")}</SelectItem>
                      <SelectItem value="monthly">{t("frequency.monthly")}</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-2">
                  <Label>
                    {t("create.emails.label")}{" "}
                    <span className="text-xs font-normal text-muted-foreground">
                      {type === "rotation"
                        ? t("create.emails.hintRotation", { count: maxInvites })
                        : t("create.emails.hintAccumulation")}
                    </span>
                  </Label>
                  <Input className="mh-input" value={emails} onChange={e => setEmails(e.target.value)} placeholder={t("create.emails.placeholder")} />
                  {emailCount > maxInvites && (
                    <p className="text-xs text-destructive">
                      {type === "rotation"
                        ? t("create.emails.tooManyRotation", { size: groupNum, count: maxInvites })
                        : t("create.emails.tooManyAccumulation")}
                    </p>
                  )}
                </div>
                <div className="grid grid-cols-2 gap-3 rounded-2xl border border-jade-500/15 bg-jade-50/50 p-4 dark:bg-jade-500/10">
                  <div>
                    <p className="font-mono text-[10px] uppercase tracking-wide text-muted-foreground">{t("create.summary.youPay")}</p>
                    <p className="font-semibold text-foreground"><Money cents={payPerRoundCents} /></p>
                  </div>
                  <div>
                    <p className="font-mono text-[10px] uppercase tracking-wide text-muted-foreground">
                      {type === "accumulation" ? t("create.summary.youReceiveEnd") : t("create.summary.youReceive")}
                    </p>
                    <p className="font-semibold text-foreground"><Money cents={receiveCents} /></p>
                  </div>
                  {type === "rotation" ? (
                    <p className="col-span-2 text-xs text-muted-foreground">
                      {t("create.summary.rotationDetail", {
                        count: groupNum || 0,
                        base: formatMoney(baseCents),
                        fee: formatMoney(rotationFeeCents),
                        payout: formatMoney(rotationReceiveCents),
                      })}
                    </p>
                  ) : (
                    <p className="col-span-2 text-xs text-muted-foreground">
                      {t("create.summary.accumulationDetail", { count: roundsNum || 0 })}
                    </p>
                  )}
                </div>
                <ImageUploadField
                  label={t("create.image.label")}
                  hint={t("create.image.hint")}
                  value={imageUrl}
                  onChange={setImageUrl}
                />
                <Button
                  type="submit"
                  className="w-full"
                  disabled={createMutation.isPending || emailCount > maxInvites || rotationInvalid}
                >
                  {createMutation.isPending ? t("create.submitting") : t("create.submit")}
                </Button>
              </form>
            </DialogContent>
          </Dialog>
        }
      />

      {visible.length > 0 && (
        <div className="grid gap-4 sm:grid-cols-3">
          <MetricCard
            label={t("status.active")}
            value={activeCount}
            icon={<Users className="h-5 w-5" />}
          />
          <MetricCard
            label={t("card.perRound")}
            value={<Money cents={totalPerRound} />}
            icon={<Repeat className="h-5 w-5" />}
          />
          <MetricCard
            label={t("card.youReceive")}
            value={<Money cents={totalPayout} />}
            icon={<Coins className="h-5 w-5" />}
          />
        </div>
      )}

      <GlassCard className="flex items-center gap-4 mh-card-highlight">
        <span className="hidden size-11 shrink-0 items-center justify-center rounded-2xl bg-jade-500 text-white sm:flex">
          <ShieldCheck className="h-6 w-6" />
        </span>
        <p className="text-sm text-foreground">
          <Trans
            t={t}
            i18nKey="info.susu"
            components={{
              b: <span className="font-semibold text-foreground" />,
              em: <span className="font-medium text-foreground" />,
            }}
          />
        </p>
      </GlassCard>

      {inviteList.length > 0 && (
        <GlassCard>
          <div className="flex items-center gap-2">
            <Inbox className="h-5 w-5 text-jade-600 dark:text-jade-400" />
            <h2 className="font-display text-lg font-bold text-foreground">
              {t("invites.title", { count: inviteList.length })}
            </h2>
          </div>
          <ul className="mt-4 space-y-3">
            {inviteList.map((inv) => (
              <li
                key={inv.id}
                className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-[var(--mh-border)] bg-[var(--mh-track)] p-4"
              >
                <div>
                  <p className="font-semibold text-foreground">{inv.circleName}</p>
                  <p className="text-xs text-muted-foreground">
                    {t("invites.invitedBy", { name: inv.inviterName })} · <Money cents={inv.contributionCents} />/{t(`frequency.${inv.frequency}`, { defaultValue: inv.frequency })}
                  </p>
                </div>
                <div className="flex items-center gap-2">
                  <ActionButton
                    onClick={() => {
                      acceptMutation.mutate({ id: inv.id }, {
                        onSuccess: () => {
                          queryClient.invalidateQueries({ queryKey: getListInvitesQueryKey() });
                          queryClient.invalidateQueries({ queryKey: getListCirclesQueryKey() });
                        }
                      });
                    }}
                    label={t("invites.accept")}
                    pendingLabel="…"
                    size="sm"
                    pending={acceptMutation.isPending}
                  />
                  <ActionButton
                    onClick={() => {
                      declineMutation.mutate({ id: inv.id }, {
                        onSuccess: () => {
                          queryClient.invalidateQueries({ queryKey: getListInvitesQueryKey() });
                        }
                      });
                    }}
                    label={t("invites.decline")}
                    pendingLabel="…"
                    size="sm"
                    variant="secondary"
                    pending={declineMutation.isPending}
                  />
                </div>
              </li>
            ))}
          </ul>
        </GlassCard>
      )}

      <div className="grid gap-5 md:grid-cols-2">
        {visible.map((circle) => (
          <Link key={circle.id} href={`/circles/${circle.id}`} className="group block">
            <GlassCard hover className="h-full overflow-hidden p-0">
              {circle.imageUrl && (
                <div className="h-32 w-full overflow-hidden bg-background">
                  <img
                    src={avatarSrc(circle.imageUrl)}
                    alt=""
                    className="h-full w-full object-cover transition-transform duration-200 group-hover:scale-[1.03]"
                  />
                </div>
              )}
              <div className="p-6">
              <div className="flex items-start justify-between gap-3">
                <div className="flex items-center gap-3">
                  <span className="flex size-11 shrink-0 items-center justify-center rounded-2xl bg-ink-900 text-white">
                    <Users className="h-5 w-5" />
                  </span>
                  <div className="min-w-0">
                    <p className="truncate font-semibold text-foreground">{circle.name}</p>
                    <p className="text-xs capitalize text-muted-foreground">
                      {t(`frequency.${circle.frequency}`, { defaultValue: circle.frequency })} · {t("card.members", { count: circle.memberCount })}
                    </p>
                  </div>
                </div>
                <div className="flex shrink-0 flex-col items-end gap-1.5">
                  <StatusPill tone={statusTone[circle.status] ?? "neutral"} className="capitalize">
                    {t(`status.${circle.status}`, { defaultValue: circle.status })}
                  </StatusPill>
                  <Badge tone="neutral">
                    {circle.type === "accumulation" ? t("type.accumulation") : t("type.rotation")}
                  </Badge>
                </div>
              </div>

              <div className="mt-5 grid grid-cols-2 gap-3">
                <div className="rounded-2xl border border-[var(--mh-border)] bg-[var(--mh-track)] px-4 py-3">
                  <p className="mh-kicker">
                    {t("card.perRound")}
                  </p>
                  <p className="mt-1 font-semibold text-foreground">
                    <Money cents={circle.contributionCents} />
                  </p>
                </div>
                <div className="rounded-2xl border border-[var(--mh-border)] bg-[var(--mh-track)] px-4 py-3">
                  <p className="mh-kicker">{t("card.youReceive")}</p>
                  <p className="mt-1 font-semibold text-foreground"><Money cents={circle.payoutCents} /></p>
                </div>
              </div>

              {circle.status === "active" ? (
                <div className="mt-5">
                  <div className="flex items-center justify-between text-xs text-muted-foreground">
                    <span>
                      {t("card.roundOf", { current: circle.currentRound, total: circle.totalRounds })}
                    </span>
                  </div>
                  <ProgressLine value={pct(circle.currentRound, circle.totalRounds)} className="mt-2" />
                </div>
              ) : (
                <div className="mt-5 flex items-center gap-2">
                  <span className="text-xs text-muted-foreground">
                    {circle.targetMembers
                      ? t("card.joinedProgress", { joined: circle.memberCount, target: circle.targetMembers })
                      : t("card.forming")}
                  </span>
                </div>
              )}

              <div className="mt-5 inline-flex items-center gap-1.5 text-sm font-medium text-jade-600 dark:text-jade-400">
                {t("card.viewCircle")}{" "}
                <ArrowRight className="h-4 w-4 transition-transform group-hover:translate-x-0.5 rtl:rotate-180" />
              </div>
              </div>
            </GlassCard>
          </Link>
        ))}

        <button
          onClick={() => setIsCreateOpen(true)}
          className="mh-glass-hover flex min-h-[230px] flex-col items-center justify-center gap-3 rounded-[var(--mh-radius-lg)] border-2 border-dashed border-[var(--mh-border)] p-6 text-muted-foreground transition-[color,border-color,transform] duration-150 hover:border-jade-500/35 hover:text-jade-600 active:scale-[0.99] focus-ring"
        >
          <span className="flex size-12 items-center justify-center rounded-2xl border border-[var(--mh-border)] bg-[var(--mh-track)]">
            <Plus className="h-6 w-6" />
          </span>
          <span className="text-sm font-semibold">{t("create.startCircle")}</span>
          <span className="max-w-[200px] text-center text-xs">
            {t("list.emptyHint")}
          </span>
        </button>
      </div>

      <Eyebrow className="pt-4 text-center text-muted-foreground">{t("common:app.tagline")}</Eyebrow>
    </div>
  );
}
