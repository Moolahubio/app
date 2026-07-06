import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import {
  Gift,
  Users,
  Wallet as WalletIcon,
  Share2,
  ArrowUpRight,
  Sparkles,
  Trophy,
  Clock,
  ShieldCheck,
  Flame,
  Link2,
  Medal,
  Award,
  Crown,
  Gem,
  Send,
  TrendingUp,
  Briefcase,
  Lock,
  Pencil,
  Check,
  X,
  type LucideIcon,
} from "lucide-react";
import { Card, Badge, Button } from "@/components/ui";
import { PageHeader, BackLink, Money } from "@/components/app/bits";
import { CopyButton } from "@/components/app/forms";
import {
  useGetReferralOverview,
  useWithdrawReferralEarnings,
  useSetReferralCode,
  getGetReferralOverviewQueryKey,
  getGetWalletQueryKey,
  getGetDashboardSummaryQueryKey,
} from "@workspace/api-client-react";
import { formatMoney, apiErrorMessage } from "@/lib/utils";
import { useStepUpGate } from "@/components/app/StepUpDialog";
import { toast } from "@/hooks/use-toast";

/** Tier ladder — mirrors the backend REFERRAL_TIERS (min active savers → rate %). */
const TIERS = [
  { key: "starter", min: 0, rate: 10 },
  { key: "builder", min: 6, rate: 12.5 },
  { key: "connector", min: 21, rate: 15 },
  { key: "leader", min: 51, rate: 17.5 },
  { key: "champion", min: 101, rate: 20 },
] as const;

/**
 * A unique icon per tier (metal/gem ladder). Keyed by the stable backend tier
 * key; only the display name + icon are cosmetic, the keys never change.
 */
const TIER_ICONS: Record<string, LucideIcon> = {
  starter: Medal,
  builder: Award,
  connector: Trophy,
  leader: Crown,
  champion: Gem,
};

/** Icon per "how it works" step. */
const HOW_ICONS: Record<string, LucideIcon> = {
  share: Send,
  save: TrendingUp,
  earn: Briefcase,
};

/** Custom referral code format (mirrors the backend rule). */
const CUSTOM_CODE_RE = /^[A-Z0-9]{4,15}$/;

export default function ReferEarnPage() {
  const { t } = useTranslation("referrals");
  const { data: overview, isLoading, isError, error, refetch } = useGetReferralOverview();

  const queryClient = useQueryClient();
  const withdraw = useWithdrawReferralEarnings();
  const setCode = useSetReferralCode();
  const { requestProof, stepUpDialog } = useStepUpGate();

  const [amount, setAmount] = useState("");
  const [formError, setFormError] = useState<string | null>(null);

  // Custom-code editor state.
  const [editingCode, setEditingCode] = useState(false);
  const [codeDraft, setCodeDraft] = useState("");
  const [codeError, setCodeError] = useState<string | null>(null);
  const [confirmingCode, setConfirmingCode] = useState(false);

  if (isError && !overview) {
    return (
      <div className="flex flex-col items-center gap-3 p-8 text-center">
        <p className="text-sm text-muted-foreground">{apiErrorMessage(error) ?? t("states.error")}</p>
        <Button variant="secondary" size="sm" onClick={() => refetch()}>
          {t("states.retry")}
        </Button>
      </div>
    );
  }

  if (isLoading || !overview) {
    return <div className="p-8 text-center text-muted-foreground">{t("states.loading")}</div>;
  }

  const o = overview;
  const w = o.withdrawal;
  const ratePct = o.tier.rateBps / 100;
  const nextAt = o.tier.nextTierAtActive ?? null;
  const nextKey = o.tier.nextTierKey ?? null;
  const maxWithdrawable = Math.max(0, Math.min(o.availableCents, w.remainingThisMonthCents));

  const TierIcon = TIER_ICONS[o.tier.key] ?? Trophy;

  // Progress within the current tier toward the next threshold.
  const progressPct =
    nextAt && nextAt > o.tier.minActive
      ? Math.min(100, Math.round(((o.activeReferrals - o.tier.minActive) / (nextAt - o.tier.minActive)) * 100))
      : 100;

  const startEditCode = () => {
    setCodeDraft(o.code);
    setCodeError(null);
    setConfirmingCode(false);
    setEditingCode(true);
  };

  const cancelEditCode = () => {
    setEditingCode(false);
    setConfirmingCode(false);
    setCodeError(null);
  };

  // Validate locally, then require an explicit confirm before saving: changing
  // a code frees the old one and breaks any links already shared.
  const reviewCode = () => {
    setCodeError(null);
    const next = codeDraft.trim().toUpperCase();
    if (!CUSTOM_CODE_RE.test(next)) {
      setCodeError(t("code.errors.format"));
      return;
    }
    if (next === o.code) {
      setCodeError(t("code.errors.unchanged"));
      return;
    }
    setConfirmingCode(true);
  };

  const saveCode = () => {
    const next = codeDraft.trim().toUpperCase();
    setCode.mutate(
      { data: { code: next } },
      {
        onSuccess: () => {
          queryClient.invalidateQueries({ queryKey: getGetReferralOverviewQueryKey() });
          setEditingCode(false);
          setConfirmingCode(false);
          setCodeError(null);
          toast({ title: t("code.success") });
        },
        onError: (err) => {
          setConfirmingCode(false);
          setCodeError(apiErrorMessage(err) ?? t("states.error"));
        },
      },
    );
  };

  const handleWithdraw = async () => {
    setFormError(null);
    const cents = Math.round(parseFloat(amount) * 100);
    if (!amount || Number.isNaN(cents) || cents <= 0) {
      setFormError(t("withdraw.errors.amount"));
      return;
    }
    if (cents < w.minCents) {
      setFormError(t("withdraw.errors.min", { amount: formatMoney(w.minCents) }));
      return;
    }
    if (cents > o.availableCents) {
      setFormError(t("withdraw.errors.max", { amount: formatMoney(o.availableCents) }));
      return;
    }
    if (cents > w.remainingThisMonthCents) {
      setFormError(
        t("withdraw.errors.monthly", {
          cap: formatMoney(w.maxMonthlyCents),
          amount: formatMoney(w.remainingThisMonthCents),
        }),
      );
      return;
    }
    // Moving money — confirm it's really you first (password + 2FA as configured).
    const proof = await requestProof();
    if (!proof) return;
    withdraw.mutate(
      { data: { amountCents: cents, ...proof } },
      {
        onSuccess: () => {
          queryClient.invalidateQueries({ queryKey: getGetReferralOverviewQueryKey() });
          queryClient.invalidateQueries({ queryKey: getGetWalletQueryKey() });
          queryClient.invalidateQueries({ queryKey: getGetDashboardSummaryQueryKey() });
          setAmount("");
          toast({ title: t("withdraw.success") });
        },
      },
    );
  };

  const handleShare = async () => {
    const shareData = {
      title: t("code.shareTitle"),
      text: t("code.shareText"),
      url: o.link,
    };
    if (typeof navigator !== "undefined" && navigator.share) {
      try {
        await navigator.share(shareData);
        return;
      } catch {
        // user dismissed the share sheet — fall through to clipboard
      }
    }
    if (typeof navigator !== "undefined" && navigator.clipboard) {
      await navigator.clipboard.writeText(o.link);
      toast({ title: t("common:forms.copied") });
    }
  };

  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <BackLink href="/profile" label={t("common:actions.back")} />
      <PageHeader eyebrow={t("eyebrow")} title={t("title")} description={t("description")} />

      {/* hero — tier, rate, lifetime */}
      <Card className="relative isolate overflow-hidden border-0 bg-ink-950 p-6 text-white lg:p-8">
        <div className="absolute inset-0 -z-10 bg-grid-dark [background-size:32px_32px] [mask-image:radial-gradient(70%_80%_at_90%_0%,black,transparent)]" />
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <p className="font-mono text-[10px] uppercase tracking-[0.2em] text-white/60">
              {t("hero.tierLabel")}
            </p>
            <div className="mt-1.5 flex items-center gap-2">
              <TierIcon className="h-6 w-6 text-jade-400" />
              <h2 className="font-display text-2xl font-bold">{t(`tier.names.${o.tier.key}`)}</h2>
            </div>
            <p className="mt-2 text-sm text-white/70">
              {t("hero.rateLabel")}{" "}
              <span className="font-semibold text-jade-300">{t("hero.rateValue", { rate: ratePct })}</span>
            </p>
          </div>
          <Badge tone="jade" className="bg-jade-500/15 text-jade-300 ring-jade-400/20">
            {t("hero.activeLabel", { count: o.activeReferrals })}
          </Badge>
        </div>

        <div className="mt-6 rounded-2xl border border-white/10 bg-white/[0.03] p-4">
          <p className="font-mono text-[10px] uppercase tracking-[0.18em] text-white/60">
            {t("hero.lifetimeLabel")}
          </p>
          <p className="mt-1 font-display text-4xl font-bold">
            <Money cents={o.lifetimeCents} />
          </p>
        </div>
      </Card>

      {/* invite link + code */}
      <Card className="p-6">
        <div className="flex items-center gap-3">
          <span className="flex h-11 w-11 items-center justify-center rounded-2xl bg-jade-50 text-jade-600 dark:bg-jade-500/15 dark:text-jade-300">
            <Gift className="h-5 w-5" />
          </span>
          <div>
            <h2 className="font-display text-lg font-bold text-foreground">{t("code.title")}</h2>
            <p className="text-xs text-muted-foreground">{t("code.subtitle")}</p>
          </div>
        </div>

        <div className="mt-5 space-y-3">
          {editingCode ? (
            <div>
              <p className="mb-1.5 font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
                {t("code.codeLabel")}
              </p>
              <input
                dir="ltr"
                value={codeDraft}
                onChange={(e) => setCodeDraft(e.target.value.toUpperCase())}
                maxLength={15}
                autoFocus
                disabled={setCode.isPending}
                placeholder={t("code.placeholder")}
                className="w-full rounded-xl border border-border bg-background px-4 py-3 font-mono text-lg font-bold tracking-[0.2em] text-foreground outline-none transition-colors placeholder:font-sans placeholder:text-sm placeholder:tracking-normal placeholder:text-muted-foreground focus:border-jade-500/60 focus-ring disabled:opacity-60"
              />
              <p className="mt-1.5 text-xs text-muted-foreground">{t("code.editHint")}</p>

              {codeError && (
                <p className="mt-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
                  {codeError}
                </p>
              )}

              {confirmingCode ? (
                <div className="mt-3 rounded-xl border border-amber-500/30 bg-amber-50/70 p-3 dark:bg-amber-500/10">
                  <p className="text-sm font-semibold text-foreground">{t("code.confirmTitle")}</p>
                  <p className="mt-1 text-xs text-muted-foreground">{t("code.confirmBody")}</p>
                  <div className="mt-3 flex gap-2">
                    <button
                      type="button"
                      onClick={saveCode}
                      disabled={setCode.isPending}
                      className="inline-flex items-center gap-1.5 rounded-lg bg-jade-500 px-3 py-2 text-xs font-semibold text-white transition-colors hover:bg-jade-400 focus-ring disabled:opacity-50"
                    >
                      <Check className="h-3.5 w-3.5" />
                      {setCode.isPending ? t("code.saving") : t("code.confirmAction")}
                    </button>
                    <button
                      type="button"
                      onClick={() => setConfirmingCode(false)}
                      disabled={setCode.isPending}
                      className="rounded-lg border border-border px-3 py-2 text-xs font-semibold text-foreground transition-colors hover:bg-muted focus-ring disabled:opacity-50"
                    >
                      {t("code.cancel")}
                    </button>
                  </div>
                </div>
              ) : (
                <div className="mt-3 flex gap-2">
                  <button
                    type="button"
                    onClick={reviewCode}
                    className="inline-flex items-center gap-1.5 rounded-lg bg-jade-500 px-3 py-2 text-xs font-semibold text-white transition-colors hover:bg-jade-400 focus-ring"
                  >
                    <Check className="h-3.5 w-3.5" /> {t("code.save")}
                  </button>
                  <button
                    type="button"
                    onClick={cancelEditCode}
                    className="inline-flex items-center gap-1.5 rounded-lg border border-border px-3 py-2 text-xs font-semibold text-foreground transition-colors hover:bg-muted focus-ring"
                  >
                    <X className="h-3.5 w-3.5" /> {t("code.cancel")}
                  </button>
                </div>
              )}
            </div>
          ) : (
            <div>
              <div className="mb-1.5 flex items-center justify-between">
                <p className="font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
                  {t("code.codeLabel")}
                </p>
                <button
                  type="button"
                  onClick={startEditCode}
                  className="inline-flex items-center gap-1 text-xs font-semibold text-jade-600 transition-colors hover:text-jade-500 focus-ring dark:text-jade-400"
                >
                  <Pencil className="h-3 w-3" /> {t("code.edit")}
                </button>
              </div>
              <div className="flex items-center justify-between gap-3 rounded-xl border border-border bg-muted/40 px-4 py-3">
                <code dir="ltr" className="font-mono text-lg font-bold tracking-[0.2em] text-foreground">
                  {o.code}
                </code>
                <CopyButton value={o.code} />
              </div>
            </div>
          )}

          <div>
            <p className="mb-1.5 font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
              {t("code.linkLabel")}
            </p>
            <div className="flex items-center justify-between gap-3 rounded-xl border border-border bg-muted/40 px-4 py-3">
              <span className="flex min-w-0 items-center gap-2">
                <Link2 className="h-4 w-4 shrink-0 text-muted-foreground" />
                <code dir="ltr" className="truncate font-mono text-sm text-foreground">
                  {o.link}
                </code>
              </span>
              <CopyButton value={o.link} />
            </div>
          </div>

          <button
            type="button"
            onClick={handleShare}
            className="inline-flex w-full items-center justify-center gap-2 rounded-xl bg-jade-500 px-4 py-2.5 text-sm font-semibold text-white transition-colors hover:bg-jade-400 focus-ring"
          >
            <Share2 className="h-4 w-4" />
            {t("code.share")}
          </button>
        </div>
      </Card>

      {/* stats */}
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Card className="p-4">
          <Users className="h-5 w-5 text-jade-500" />
          <p className="mt-2 font-display text-2xl font-bold text-foreground tabular-nums">{o.activeReferrals}</p>
          <p className="text-xs text-muted-foreground">{t("stats.activeReferrals")}</p>
        </Card>
        <Card className="p-4">
          <Sparkles className="h-5 w-5 text-jade-500" />
          <p className="mt-2 font-display text-2xl font-bold text-foreground tabular-nums">{o.totalReferred}</p>
          <p className="text-xs text-muted-foreground">{t("stats.totalReferred")}</p>
        </Card>
        <Card className="p-4">
          <WalletIcon className="h-5 w-5 text-jade-500" />
          <p className="mt-2 font-display text-2xl font-bold text-foreground">
            <Money cents={o.availableCents} />
          </p>
          <p className="text-xs text-muted-foreground">{t("stats.available")}</p>
        </Card>
        <Card className="p-4">
          <Clock className="h-5 w-5 text-amber-500" />
          <p className="mt-2 font-display text-2xl font-bold text-foreground">
            <Money cents={o.pendingCents} />
          </p>
          <p className="text-xs text-muted-foreground">{t("stats.pending")}</p>
        </Card>
      </div>

      {/* tier ladder */}
      <Card className="p-6">
        <h2 className="font-display text-lg font-bold text-foreground">{t("tier.title")}</h2>
        <p className="mt-1 text-sm text-muted-foreground">{t("tier.subtitle")}</p>

        {nextAt && nextKey ? (
          <div className="mt-4">
            <div className="flex items-center justify-between text-sm">
              <span className="font-medium text-foreground">{t(`tier.names.${o.tier.key}`)}</span>
              <span className="text-muted-foreground">{t(`tier.names.${nextKey}`)}</span>
            </div>
            <div className="mt-2 h-2 w-full overflow-hidden rounded-full bg-muted">
              <div className="h-full rounded-full bg-jade-500 transition-all" style={{ width: `${progressPct}%` }} />
            </div>
            <p className="mt-2 text-xs text-muted-foreground">
              {t("tier.progressToNext", {
                count: Math.max(0, nextAt - o.activeReferrals),
                tier: t(`tier.names.${nextKey}`),
              })}
            </p>
          </div>
        ) : (
          <p className="mt-4 rounded-xl bg-jade-50/60 px-4 py-3 text-sm font-medium text-jade-700 dark:bg-jade-500/10 dark:text-jade-300">
            {t("tier.maxed", { rate: ratePct })}
          </p>
        )}

        <ul className="mt-5 divide-y divide-border">
          {TIERS.map((tier) => {
            const isCurrent = tier.key === o.tier.key;
            const RowIcon = TIER_ICONS[tier.key] ?? Trophy;
            return (
              <li
                key={tier.key}
                className={`flex items-center justify-between gap-3 py-3 ${isCurrent ? "opacity-100" : "opacity-70"}`}
              >
                <div className="flex items-center gap-3">
                  <span
                    className={`flex h-9 w-9 items-center justify-center rounded-xl ${
                      isCurrent
                        ? "bg-jade-500 text-white"
                        : "bg-muted text-muted-foreground"
                    }`}
                  >
                    <RowIcon className="h-4 w-4" />
                  </span>
                  <div>
                    <p className="text-sm font-semibold text-foreground">{t(`tier.names.${tier.key}`)}</p>
                    <p className="text-xs text-muted-foreground">
                      {t("tier.activeRange", { min: tier.min })}
                    </p>
                  </div>
                </div>
                <div className="flex items-center gap-2">
                  <span className="font-display text-base font-bold text-foreground tabular-nums">{tier.rate}%</span>
                  {isCurrent && (
                    <Badge tone="jade" className="text-[10px]">
                      {t("tier.current")}
                    </Badge>
                  )}
                </div>
              </li>
            );
          })}
        </ul>
      </Card>

      {/* withdraw */}
      <Card className="p-6">
        <div className="flex items-center gap-3">
          <span className="flex h-11 w-11 items-center justify-center rounded-2xl bg-muted text-foreground">
            <ArrowUpRight className="h-5 w-5" />
          </span>
          <div>
            <h2 className="font-display text-lg font-bold text-foreground">{t("withdraw.title")}</h2>
            <p className="text-xs text-muted-foreground">{t("withdraw.subtitle")}</p>
          </div>
        </div>

        {maxWithdrawable < w.minCents ? (
          <div className="mt-5 rounded-xl border border-border bg-muted/30 p-4">
            <div className="flex items-center gap-2 text-sm font-semibold text-foreground">
              <Lock className="h-4 w-4 text-muted-foreground" />
              {t("withdraw.locked.title", { min: formatMoney(w.minCents) })}
            </div>
            {o.availableCents < w.minCents ? (
              <>
                <div className="mt-3 h-2 w-full overflow-hidden rounded-full bg-muted">
                  <div
                    className="h-full rounded-full bg-jade-500 transition-all"
                    style={{ width: `${Math.min(100, Math.round((o.availableCents / w.minCents) * 100))}%` }}
                  />
                </div>
                <p className="mt-2 text-xs text-muted-foreground">
                  {t("withdraw.locked.progress", {
                    current: formatMoney(o.availableCents),
                    min: formatMoney(w.minCents),
                  })}
                </p>
                <p className="mt-2 text-sm text-muted-foreground">
                  {t("withdraw.locked.needMore", { amount: formatMoney(w.minCents - o.availableCents) })}
                </p>
              </>
            ) : (
              <div className="mt-3">
                <p className="text-sm text-muted-foreground">
                  {t("withdraw.locked.monthlyReached", { cap: formatMoney(w.maxMonthlyCents) })}
                </p>
                <div className="mt-3 h-1.5 w-full overflow-hidden rounded-full bg-muted">
                  <div
                    className="h-full rounded-full bg-ink-800 dark:bg-white/40"
                    style={{
                      width: `${Math.min(100, Math.round((w.withdrawnThisMonthCents / w.maxMonthlyCents) * 100))}%`,
                    }}
                  />
                </div>
                <p className="mt-1.5 text-xs text-muted-foreground">
                  {t("withdraw.monthly", {
                    used: formatMoney(w.withdrawnThisMonthCents),
                    cap: formatMoney(w.maxMonthlyCents),
                  })}
                </p>
              </div>
            )}
          </div>
        ) : (
        <div className="mt-5 space-y-3">
          <div className="flex items-center gap-2">
            <div className="relative flex-1">
              <span
                dir="ltr"
                className="pointer-events-none absolute inset-y-0 start-3 flex items-center text-sm text-muted-foreground"
              >
                $
              </span>
              <input
                type="number"
                inputMode="decimal"
                min={w.minCents / 100}
                step="0.01"
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
                placeholder={t("withdraw.amountPlaceholder")}
                className="w-full rounded-xl border border-border bg-background py-2.5 pe-3 ps-7 text-sm text-foreground outline-none transition-colors placeholder:text-muted-foreground focus:border-jade-500/60 focus-ring"
              />
            </div>
            <button
              type="button"
              onClick={() => setAmount(String(maxWithdrawable / 100))}
              disabled={maxWithdrawable < w.minCents}
              className="shrink-0 rounded-xl border border-border px-3 py-2.5 text-xs font-semibold text-foreground transition-colors hover:border-jade-500/40 disabled:opacity-50"
            >
              {t("withdraw.maxAction")}
            </button>
            <button
              type="button"
              onClick={handleWithdraw}
              disabled={withdraw.isPending || maxWithdrawable < w.minCents}
              className="shrink-0 rounded-xl bg-jade-500 px-4 py-2.5 text-sm font-semibold text-white transition-colors hover:bg-jade-400 focus-ring disabled:opacity-50"
            >
              {withdraw.isPending ? t("withdraw.submitting") : t("withdraw.submit")}
            </button>
          </div>

          <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-muted-foreground">
            <span>{t("withdraw.min", { amount: formatMoney(w.minCents) })}</span>
            <span>{t("withdraw.max", { amount: formatMoney(o.availableCents) })}</span>
          </div>

          {/* monthly cap meter */}
          <div>
            <div className="h-1.5 w-full overflow-hidden rounded-full bg-muted">
              <div
                className="h-full rounded-full bg-ink-800 dark:bg-white/40"
                style={{
                  width: `${Math.min(100, Math.round((w.withdrawnThisMonthCents / w.maxMonthlyCents) * 100))}%`,
                }}
              />
            </div>
            <p className="mt-1.5 text-xs text-muted-foreground">
              {t("withdraw.monthly", {
                used: formatMoney(w.withdrawnThisMonthCents),
                cap: formatMoney(w.maxMonthlyCents),
              })}
            </p>
          </div>

          {formError && (
            <p className="text-sm text-red-600 dark:text-red-400" role="alert">
              {formError}
            </p>
          )}
          {withdraw.isError && !formError && (
            <p className="text-sm text-red-600 dark:text-red-400" role="alert">
              {apiErrorMessage(withdraw.error)}
            </p>
          )}
        </div>
        )}
        {stepUpDialog}
      </Card>

      {/* referrals list */}
      <Card className="p-6">
        <h2 className="font-display text-lg font-bold text-foreground">{t("referrals.title")}</h2>
        <p className="mt-1 text-sm text-muted-foreground">{t("referrals.subtitle")}</p>

        {o.referrals.length === 0 ? (
          <p className="mt-5 rounded-xl border border-dashed border-border px-4 py-8 text-center text-sm text-muted-foreground">
            {t("referrals.empty")}
          </p>
        ) : (
          <ul className="mt-4 divide-y divide-border">
            {o.referrals.map((r, i) => (
              <li key={`${r.username ?? r.name}-${i}`} className="flex items-center justify-between gap-3 py-3">
                <div className="min-w-0">
                  <p className="truncate text-sm font-semibold text-foreground">
                    {r.username ? `@${r.username}` : r.name}
                  </p>
                  <p className="text-xs text-muted-foreground">{t("referrals.joined", { date: r.joinedAt })}</p>
                </div>
                <div className="flex items-center gap-3">
                  {r.activityCount > 0 && (
                    <span className="inline-flex items-center gap-1 text-xs text-muted-foreground">
                      <Flame className="h-3.5 w-3.5 text-jade-500" />
                      {r.activityCount}
                    </span>
                  )}
                  <div className="text-end">
                    <p className="text-sm font-semibold text-foreground">
                      <Money cents={r.feesEarnedCents} />
                    </p>
                    <Badge
                      tone={r.status === "active" ? "jade" : "neutral"}
                      className="text-[10px]"
                    >
                      {t(`referrals.status.${r.status}`)}
                    </Badge>
                  </div>
                </div>
              </li>
            ))}
          </ul>
        )}
      </Card>

      {/* how it works */}
      <Card className="p-6">
        <h2 className="font-display text-lg font-bold text-foreground">{t("how.title")}</h2>
        <ol className="mt-4 space-y-4">
          {(["share", "save", "earn"] as const).map((step) => {
            const StepIcon = HOW_ICONS[step];
            return (
              <li key={step} className="flex gap-3">
                <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-jade-50 text-jade-600 dark:bg-jade-500/15 dark:text-jade-300">
                  <StepIcon className="h-4 w-4" />
                </span>
                <div>
                  <p className="text-sm font-semibold text-foreground">{t(`how.steps.${step}.title`)}</p>
                  <p className="text-sm text-muted-foreground">
                    {t(`how.steps.${step}.desc`, { rate: ratePct })}
                  </p>
                </div>
              </li>
            );
          })}
        </ol>
      </Card>

      <Card className="flex items-start gap-3 border-jade-500/15 bg-jade-50/60 p-5 dark:bg-jade-500/10">
        <ShieldCheck className="mt-0.5 h-5 w-5 shrink-0 text-jade-600" />
        <p className="text-sm text-muted-foreground">
          {t("limits.note", { min: formatMoney(w.minCents), max: formatMoney(w.maxMonthlyCents) })}
        </p>
      </Card>
    </div>
  );
}
