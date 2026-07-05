import { useParams, useLocation } from "wouter";
import { Repeat, Calendar, Target, Sparkles, Link2, ExternalLink, Trash2 } from "lucide-react";
import { GlassCard, StatusPill } from "@/components/ui";
import { BackLink, Money, Addr } from "@/components/app/bits";
import { AmountForm } from "@/components/app/forms";
import { PrivyGoalDepositForm, PrivyGoalReleaseForm } from "@/components/app/PrivyGoalForms";
import { isWeb3Enabled } from "@/components/app/Web3Provider";
import { useOnchainConfig } from "@/lib/onchain/config";
import {
  useGetGoal,
  useGetWallet,
  useAllocateToGoal,
  useReleaseFromGoal,
  useDeleteGoal,
  getGetGoalQueryKey,
  getGetWalletQueryKey,
  getGetDashboardSummaryQueryKey,
  getListGoalsQueryKey,
  getListNotificationsQueryKey,
  getGetStreaksQueryKey,
} from "@workspace/api-client-react";
import type { ReleaseFromGoalResult } from "@workspace/api-client-react";
import { toast } from "@/hooks/use-toast";
import { formatMoney, formatDate, pct, apiErrorMessage } from "@/lib/utils";
import { asFrequency, buildGoalPlan, nextContribution } from "@/lib/contribution-plan";
import { useTranslation, Trans } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { useStepUpGate } from "@/components/app/StepUpDialog";

const EXPLORER_FALLBACK = "https://testnet.monadvision.com";

export default function GoalDetailPage() {
  const { t } = useTranslation("goals");
  const { id } = useParams();
  const [, navigate] = useLocation();
  const { data: goal, isLoading } = useGetGoal(id!, { query: { enabled: !!id, queryKey: getGetGoalQueryKey(id!) } });
  const { data: wallet } = useGetWallet();
  const { data: onchainConfig } = useOnchainConfig();

  const queryClient = useQueryClient();
  const allocateMutation = useAllocateToGoal();
  const releaseMutation = useReleaseFromGoal();
  const deleteMutation = useDeleteGoal();

  const [allocOk, setAllocOk] = useState<string | null>(null);
  const [releaseOk, setReleaseOk] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const { requestProof, stepUpDialog } = useStepUpGate();

  if (isLoading) return <div className="p-8 text-center text-[var(--mh-muted)]">{t("detail.loading")}</div>;
  if (!goal) return <div className="p-8 text-center text-[var(--mh-muted)]">{t("detail.notFound")}</div>;

  const remaining = Math.max(0, goal.targetCents - goal.savedCents);
  const progress = pct(goal.savedCents, goal.targetCents);
  const frequency = asFrequency(goal.frequency);
  const goalPlan = buildGoalPlan(goal.targetCents, goal.createdAt, goal.deadline, frequency);
  const next = nextContribution(goalPlan.plan, goal.savedCents);
  const periodsLeft = next ? goalPlan.plan.length - next.index + 1 : 0;
  const circumference = 2 * Math.PI * 52;

  const onchain = goal.onchain ?? false;
  const feeBps = goal.feeBps ?? 0;
  const feePct = (feeBps / 100).toFixed(feeBps % 100 === 0 ? 0 : 2);
  const explorer = goal.explorerUrl ?? EXPLORER_FALLBACK;
  const history = goal.history ?? [];

  // Non-custodial (Privy) wallets can't be signed by the platform, so on-chain
  // goal deposits/withdrawals must be signed by the user in-browser and only
  // confirmed server-side. Server-custody wallets keep the server-signed paths.
  const isPrivyCustody = wallet?.custody === "privy";
  const useClientSigned = onchain && isPrivyCustody && isWeb3Enabled;
  const goalVault = onchainConfig?.goalVault ?? goal.vaultAddress ?? null;
  const usdcAddress = onchainConfig?.usdc ?? null;

  const refreshGoal = () => {
    queryClient.invalidateQueries({ queryKey: getGetGoalQueryKey(goal.id) });
    queryClient.invalidateQueries({ queryKey: getGetWalletQueryKey() });
    queryClient.invalidateQueries({ queryKey: getGetDashboardSummaryQueryKey() });
    queryClient.invalidateQueries({ queryKey: getListNotificationsQueryKey() });
  };

  return (
    <div className="mx-auto max-w-4xl space-y-6">
      <BackLink href="/goals" label={t("common:nav.personalSavings")} />

      <div className="grid gap-6 md:grid-cols-5">
        {/* progress ring */}
        <GlassCard className="flex flex-col items-center justify-center p-8 text-center md:col-span-2">
          <span className="mb-4 flex h-14 w-14 items-center justify-center rounded-2xl border border-[var(--mh-border)] bg-[rgba(45,212,166,0.09)] text-3xl">
            {goal.emoji || "🎯"}
          </span>
          <div className="relative h-40 w-40">
            <svg viewBox="0 0 120 120" className="h-full w-full -rotate-90">
              <circle cx="60" cy="60" r="52" fill="none" stroke="var(--mh-track)" strokeWidth="12" />
              <circle
                cx="60"
                cy="60"
                r="52"
                fill="none"
                stroke="#2DD4A6"
                strokeWidth="12"
                strokeLinecap="round"
                strokeDasharray={circumference}
                strokeDashoffset={circumference - (progress / 100) * circumference}
              />
            </svg>
            <div className="absolute inset-0 flex flex-col items-center justify-center">
              <span className="font-display text-3xl font-bold text-[var(--mh-text-strong)]">{progress}%</span>
              <span className="font-mono text-[10px] uppercase tracking-wide text-[var(--mh-muted)]">
                {t("detail.savedLabel")}
              </span>
            </div>
          </div>
          <h1 className="mt-5 font-display text-xl font-bold text-[var(--mh-text-strong)]">{goal.name}</h1>
          <p className="text-sm text-[var(--mh-muted)]">
            <Trans
              t={t}
              i18nKey="detail.savedOfTarget"
              components={[<Money cents={goal.savedCents} />, <Money cents={goal.targetCents} />]}
            />
          </p>
          {onchain && (
            <StatusPill tone="jade" className="mt-3">
              <Link2 className="h-3.5 w-3.5" /> {t("detail.onChain")}
            </StatusPill>
          )}
        </GlassCard>

        {/* details + actions */}
        <div className="space-y-6 md:col-span-3">
          <GlassCard>
            <h2 className="font-display text-lg font-bold text-[var(--mh-text-strong)]">{t("deposit.title")}</h2>
            <p className="mt-1 text-sm text-[var(--mh-muted)]">
              {onchain ? t("deposit.descriptionOnchain") : t("deposit.description")}
            </p>
            <div className="mt-4">
              {useClientSigned ? (
                <PrivyGoalDepositForm
                  goalId={goal.id}
                  goalVault={goalVault}
                  usdcAddress={usdcAddress}
                  presets={[1000, 2500, 5000]}
                  onSuccess={() => {
                    refreshGoal();
                    queryClient.invalidateQueries({ queryKey: getGetStreaksQueryKey() });
                    toast({
                      title: t("toast.streakTitle"),
                      description: t("toast.streakDescription"),
                    });
                  }}
                />
              ) : (
                <AmountForm
                  onSubmit={(amountCents) => {
                    setAllocOk(null);
                    allocateMutation.mutate({ id: goal.id, data: { amountCents } }, {
                      onSuccess: () => {
                        refreshGoal();
                        setAllocOk(t("deposit.success"));
                        queryClient.invalidateQueries({ queryKey: getGetStreaksQueryKey() });
                        toast({
                          title: t("toast.streakTitle"),
                          description: t("toast.streakDescription"),
                        });
                      }
                    });
                  }}
                  presets={[1000, 2500, 5000]}
                  submitLabel={t("deposit.addFunds")}
                  pending={allocateMutation.isPending}
                  error={apiErrorMessage(allocateMutation.error)}
                  ok={allocOk}
                />
              )}
            </div>
            <div className="mt-5 mh-divider" />
            <div className="mt-5">
              <p className="mb-1 text-sm font-semibold text-[var(--mh-text-strong)]">{t("withdraw.title")}</p>
              {onchain && feeBps > 0 && (
                <p className="mb-3 text-xs text-[var(--mh-muted)]">
                  {t("withdraw.feeNote", { fee: feePct })}
                </p>
              )}
              {useClientSigned ? (
                <>
                  <PrivyGoalReleaseForm
                    goalId={goal.id}
                    goalVault={goalVault}
                    onSuccess={(res: ReleaseFromGoalResult) => {
                      refreshGoal();
                      setReleaseOk(
                        res.feeCents > 0
                          ? t("withdraw.releasedWithFee", { amount: formatMoney(res.netCents), fee: formatMoney(res.feeCents) })
                          : t("withdraw.released", { amount: formatMoney(res.netCents) }),
                      );
                    }}
                  />
                  {releaseOk && (
                    <p className="mt-2 text-sm text-[var(--mh-mint)]">{releaseOk}</p>
                  )}
                </>
              ) : (
                <AmountForm
                  onSubmit={async (amountCents) => {
                    setReleaseOk(null);
                    // Withdrawing moves real funds out of the on-chain vault —
                    // confirm it's really you before we move anything.
                    const proof = await requestProof();
                    if (!proof) return;
                    releaseMutation.mutate({ id: goal.id, data: { amountCents, ...proof } }, {
                      onSuccess: (res) => {
                        refreshGoal();
                        setReleaseOk(
                          res.feeCents > 0
                            ? t("withdraw.releasedWithFee", { amount: formatMoney(res.netCents), fee: formatMoney(res.feeCents) })
                            : t("withdraw.released", { amount: formatMoney(res.netCents) }),
                        );
                      }
                    });
                  }}
                  submitLabel={t("withdraw.submit")}
                  variant="secondary"
                  pending={releaseMutation.isPending}
                  error={apiErrorMessage(releaseMutation.error)}
                  ok={releaseOk}
                />
              )}
            </div>
          </GlassCard>

          <div className="grid gap-4 sm:grid-cols-2">
            <GlassCard hover>
              <div className="flex items-center gap-2 text-[var(--mh-mint)]">
                <Target className="h-4 w-4" />
                <p className="font-mono text-[10px] uppercase tracking-[0.15em]">{t("stats.remaining")}</p>
              </div>
              <p className="mt-1.5 font-display text-xl font-bold text-[var(--mh-text-strong)]">
                <Money cents={remaining} />
              </p>
            </GlassCard>
            <GlassCard hover>
              <div className="flex items-center gap-2 text-[var(--mh-mint)]">
                <Calendar className="h-4 w-4" />
                <p className="font-mono text-[10px] uppercase tracking-[0.15em]">{t("stats.targetDate")}</p>
              </div>
              <p className="mt-1.5 font-display text-xl font-bold text-[var(--mh-text-strong)]">
                {formatDate(goal.deadline, { month: "short", day: "numeric", year: "numeric" })}
              </p>
            </GlassCard>
          </div>

          <GlassCard>
            <div className="flex items-center justify-between gap-3">
              <div className="flex items-center gap-3">
                <span className="flex h-10 w-10 items-center justify-center rounded-2xl border border-[rgba(45,212,166,0.18)] bg-[rgba(45,212,166,0.09)] text-[var(--mh-mint)]">
                  <Repeat className="h-5 w-5" />
                </span>
                <div>
                  <p className="font-semibold text-[var(--mh-text-strong)]">{t("plan.title")}</p>
                  <p className="text-sm text-[var(--mh-muted)] capitalize">{t("plan.subtitle", { cadence: t(`cadence.adverb.${frequency}`) })}</p>
                </div>
              </div>
              {next ? <StatusPill tone="jade">{t("plan.step", { current: next.index, total: next.total })}</StatusPill> : <StatusPill tone="jade">{t("plan.complete")}</StatusPill>}
            </div>
            {next ? (
              <div className="mt-4 flex items-end justify-between gap-3 border-t border-[var(--mh-border)] pt-4">
                <div>
                  <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-[var(--mh-muted)]">
                    {t("plan.nextContribution")}
                  </p>
                  <p className="mt-1 font-display text-2xl font-bold text-[var(--mh-text-strong)]">
                    <Money cents={next.amountCents} />
                  </p>
                </div>
                <p className="text-sm text-[var(--mh-muted)]">
                  {t(`plan.thisCadence.${frequency}`)}
                </p>
              </div>
            ) : (
              <p className="mt-4 border-t border-[var(--mh-border)] pt-4 text-sm text-[var(--mh-muted)]">
                {t("plan.allDone")}
              </p>
            )}
          </GlassCard>

          {next && remaining > 0 && (
            <p className="flex items-center justify-center gap-2 text-center text-sm text-[var(--mh-muted)]">
              <Sparkles className="h-4 w-4 text-[var(--mh-mint)]" />
              <Trans
                t={t}
                i18nKey={`plan.keepGoing.${frequency}`}
                values={{ count: periodsLeft }}
                components={[<span className="font-semibold text-[var(--mh-text-strong)]" />]}
              />
            </p>
          )}

          {onchain && goal.vaultAddress && (
            <GlassCard>
              <div className="flex items-center gap-2">
                <Link2 className="h-5 w-5 text-[var(--mh-mint)]" />
                <h2 className="font-display text-lg font-bold text-[var(--mh-text-strong)]">{t("vault.title")}</h2>
              </div>
              <p className="mt-1 text-sm text-[var(--mh-muted)]">
                {t("vault.description", { fee: feePct })}
              </p>
              <a
                href={`${explorer}/address/${goal.vaultAddress}`}
                target="_blank"
                rel="noreferrer"
                className="focus-ring mt-4 inline-flex items-center gap-2 rounded-xl border border-[var(--mh-border)] bg-[var(--mh-track)] px-3 py-2 font-mono text-xs text-[var(--mh-text-strong)] transition hover:border-[rgba(45,212,166,0.4)] hover:text-[var(--mh-mint)]"
              >
                <Addr address={goal.vaultAddress} />
                <ExternalLink className="h-3.5 w-3.5" />
              </a>
            </GlassCard>
          )}

          {history.length > 0 && (
            <GlassCard>
              <h2 className="font-display text-lg font-bold text-[var(--mh-text-strong)]">{t("activity.title")}</h2>
              <ul className="mt-4 space-y-2">
                {history.map((h) => (
                  <li
                    key={h.id}
                    className="flex items-center justify-between gap-3 rounded-2xl border border-[var(--mh-border)] bg-[var(--mh-track)] px-4 py-3"
                  >
                    <div className="min-w-0">
                      <p className="text-sm font-semibold capitalize text-[var(--mh-text-strong)]">
                        {t(`activity.types.${h.type}`, { defaultValue: h.type.replace(/_/g, " ") })}
                      </p>
                      <p className="text-xs text-[var(--mh-muted)]"><Money cents={h.amountCents} /></p>
                    </div>
                    {h.txHash ? (
                      <a
                        href={`${explorer}/tx/${h.txHash}`}
                        target="_blank"
                        rel="noreferrer"
                        className="focus-ring inline-flex items-center gap-1.5 font-mono text-xs text-[var(--mh-mint)] transition hover:opacity-80"
                      >
                        <Addr address={h.txHash} />
                        <ExternalLink className="h-3.5 w-3.5" />
                      </a>
                    ) : (
                      <StatusPill tone="neutral" className="capitalize">{t(`activity.status.${h.onchainStatus}`, { defaultValue: h.onchainStatus })}</StatusPill>
                    )}
                  </li>
                ))}
              </ul>
            </GlassCard>
          )}

          <GlassCard className="border-[rgba(255,107,107,0.28)]">
            <h2 className="font-display text-lg font-bold text-[var(--mh-text-strong)]">{t("delete.title")}</h2>
            <p className="mt-1 text-sm text-[var(--mh-muted)]">
              {goal.savedCents > 0
                ? onchain && feeBps > 0
                  ? t("delete.descWithFee", { amount: formatMoney(goal.savedCents), fee: feePct })
                  : t("delete.descWithBalance", { amount: formatMoney(goal.savedCents) })
                : t("delete.descEmpty")}
            </p>
            {deleteMutation.error && (
              <p className="mt-3 text-sm text-[var(--mh-danger)]">{apiErrorMessage(deleteMutation.error)}</p>
            )}
            <div className="mt-4 flex flex-wrap items-center gap-3">
              {!confirmDelete ? (
                <button
                  type="button"
                  onClick={() => setConfirmDelete(true)}
                  className="focus-ring inline-flex items-center gap-2 rounded-xl border border-[rgba(255,107,107,0.32)] bg-[rgba(255,107,107,0.06)] px-4 py-2 text-sm font-medium text-[var(--mh-danger)] transition hover:bg-[rgba(255,107,107,0.12)]"
                >
                  <Trash2 className="h-4 w-4" /> {t("delete.title")}
                </button>
              ) : (
                <>
                  <button
                    type="button"
                    disabled={deleteMutation.isPending}
                    onClick={async () => {
                      // Deleting auto-withdraws the full balance — confirm
                      // it's really you before we move anything.
                      const proof = await requestProof();
                      if (!proof) return;
                      deleteMutation.mutate(
                        { id: goal.id, data: proof },
                        {
                          onSuccess: () => {
                            queryClient.invalidateQueries({ queryKey: getListGoalsQueryKey() });
                            queryClient.invalidateQueries({ queryKey: getGetWalletQueryKey() });
                            queryClient.invalidateQueries({ queryKey: getGetDashboardSummaryQueryKey() });
                            queryClient.invalidateQueries({ queryKey: getListNotificationsQueryKey() });
                            navigate("/goals");
                          },
                        },
                      );
                    }}
                    className="focus-ring inline-flex items-center gap-2 rounded-xl bg-[var(--mh-danger)] px-4 py-2 text-sm font-medium text-white transition hover:brightness-105 disabled:opacity-60"
                  >
                    <Trash2 className="h-4 w-4" />
                    {deleteMutation.isPending ? t("delete.deleting") : t("delete.confirm")}
                  </button>
                  <button
                    type="button"
                    disabled={deleteMutation.isPending}
                    onClick={() => setConfirmDelete(false)}
                    className="mh-btn-secondary focus-ring rounded-xl px-4 py-2 text-sm font-medium"
                  >
                    {t("common:actions.cancel")}
                  </button>
                </>
              )}
            </div>
          </GlassCard>
        </div>
      </div>
      {stepUpDialog}
    </div>
  );
}
