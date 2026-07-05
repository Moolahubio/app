import { ArrowDownLeft, ArrowUpRight, Wallet as WalletIcon, ShieldCheck, Sparkles, PiggyBank } from "lucide-react";
import { GlassCard, MetricCard, StatusPill, Skeleton, GlowLineChart } from "@/components/ui";
import { PageHeader, BackLink, Money } from "@/components/app/bits";
import { AmountForm, WithdrawForm, CopyButton, ActionButton } from "@/components/app/forms";
import { WalletSetupCard } from "@/components/app/WalletSetupCard";
import { PrivyWithdrawForm } from "@/components/app/PrivyWithdrawForm";
import { isWeb3Enabled } from "@/components/app/Web3Provider";
import { useGetWallet, useDepositFaucet, useWithdrawFunds, useSyncDeposits, getGetWalletQueryKey, getGetDashboardSummaryQueryKey } from "@workspace/api-client-react";
import { formatMoney, apiErrorMessage } from "@/lib/utils";
import { useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { useTranslation, Trans } from "react-i18next";
import { useStepUpGate } from "@/components/app/StepUpDialog";

const NETWORK = import.meta.env.VITE_CHAIN_NAME ?? "Monad Testnet";

export default function WalletPage() {
  const { t } = useTranslation("wallet");
  const { data: wallet, isLoading } = useGetWallet();

  const queryClient = useQueryClient();
  const depositMutation = useDepositFaucet();
  const withdrawMutation = useWithdrawFunds();
  const syncMutation = useSyncDeposits();

  const [depositOk, setDepositOk] = useState<string | null>(null);
  const [withdrawOk, setWithdrawOk] = useState<string | null>(null);
  const [syncOk, setSyncOk] = useState<string | null>(null);
  const { requestProof, stepUpDialog } = useStepUpGate();

  if (isLoading || !wallet) {
    return (
      <div className="mx-auto max-w-3xl space-y-6">
        <Skeleton className="h-5 w-24" />
        <Skeleton className="h-16 w-72" />
        <div className="grid gap-4 sm:grid-cols-2">
          <Skeleton className="h-28" />
          <Skeleton className="h-28" />
        </div>
        <Skeleton className="h-52 w-full" />
        <div className="grid gap-6 md:grid-cols-2">
          <Skeleton className="h-72" />
          <Skeleton className="h-72" />
        </div>
      </div>
    );
  }

  if (!wallet.hasWallet) {
    return (
      <div className="mx-auto max-w-3xl space-y-6">
        <BackLink href="/dashboard" label={t("common:actions.back")} />
        <PageHeader
          eyebrow={t("eyebrow")}
          title={t("intro.getReadyTitle")}
          description={t("intro.getReadyDescription")}
        />
        <WalletSetupCard />
      </div>
    );
  }

  const isPrivyCustody = wallet.custody === "privy";

  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <BackLink href="/dashboard" label={t("common:actions.back")} />
      <PageHeader
        eyebrow={t("eyebrow")}
        title={t("intro.manageTitle")}
        description={t("intro.manageDescription")}
      />

      {/* balance + receive address */}
      <div className="mh-card-highlight relative isolate overflow-hidden rounded-[var(--mh-radius-lg)] p-6 text-white lg:p-8">
        <GlowLineChart className="pointer-events-none absolute inset-x-0 bottom-0 -z-10 h-36 w-full opacity-70" />
        <div className="flex items-center justify-between">
          <p className="font-mono text-[10px] uppercase tracking-[0.2em] text-white/70">
            {t("balance.available")}
          </p>
          <span className="inline-flex items-center gap-1.5 rounded-full border border-white/25 bg-white/15 px-2.5 py-1 text-xs font-semibold text-white">
            {NETWORK}
          </span>
        </div>
        <p className="mt-1.5 font-display text-4xl font-bold tracking-[-0.04em]">
          <Money cents={wallet.availableCents} />
        </p>
        <p className="mt-1 text-sm text-white/75">
          <Money cents={wallet.goalAllocatedCents} /> {t("balance.allocatedToSavings")}
        </p>

        {wallet.address && (
          <div className="mt-5 rounded-2xl border border-white/15 bg-white/[0.06] p-4 backdrop-blur-sm">
            <div className="flex items-center gap-2">
              <WalletIcon className="h-4 w-4 text-white" />
              <p className="font-mono text-[10px] uppercase tracking-[0.18em] text-white/70">
                {t("receive.depositAddressLabel")}
              </p>
            </div>
            <div className="mt-2 flex items-center justify-between gap-3">
              <code dir="ltr" className="truncate font-mono text-sm text-white/85">{wallet.address}</code>
              <CopyButton value={wallet.address} />
            </div>
            <p className="mt-2 text-xs text-white/70">
              <Trans
                t={t}
                i18nKey="receive.sendOnly"
                values={{ network: NETWORK }}
                components={[<span key="hl" className="text-white/90 font-medium" />]}
              />
            </p>
          </div>
        )}
      </div>

      {/* balance breakdown */}
      <div className="grid gap-4 sm:grid-cols-2">
        <MetricCard
          label={t("balance.available")}
          value={<Money cents={wallet.availableCents} />}
          icon={<WalletIcon className="h-5 w-5" />}
        />
        <MetricCard
          label={t("balance.allocatedToSavings")}
          value={<Money cents={wallet.goalAllocatedCents} />}
          icon={<PiggyBank className="h-5 w-5" />}
        />
      </div>

      <div className="grid gap-6 md:grid-cols-2">
        {/* receive */}
        <GlassCard>
          <div className="flex items-center gap-3">
            <span className="flex h-11 w-11 items-center justify-center rounded-2xl bg-jade-50 text-jade-600 dark:bg-jade-500/15 dark:text-jade-300">
              <ArrowDownLeft className="h-5 w-5" />
            </span>
            <div>
              <h2 className="font-display text-lg font-bold text-foreground">{t("receive.title")}</h2>
              <p className="text-xs text-muted-foreground">{t("receive.subtitle")}</p>
            </div>
          </div>

          <p className="mt-4 text-sm text-muted-foreground">
            {wallet.syncEnabled ? t("receive.instructionsSync") : t("receive.instructions")}
          </p>
          {wallet.syncEnabled && (
            <div className="mt-3">
              <ActionButton
                onClick={() => {
                  setSyncOk(null);
                  syncMutation.mutate(undefined, {
                    onSuccess: (res) => {
                      queryClient.invalidateQueries({ queryKey: getGetWalletQueryKey() });
                      queryClient.invalidateQueries({ queryKey: getGetDashboardSummaryQueryKey() });
                      setSyncOk(
                        res.credited > 0
                          ? t("receive.creditedDeposits", { count: res.credited, amount: formatMoney(res.totalCents ?? 0) })
                          : t("receive.noNewDeposits"),
                      );
                    }
                  });
                }}
                label={t("receive.checkForDeposits")}
                pendingLabel={t("receive.checking")}
                variant="secondary"
                className="w-full [&>button]:w-full"
                pending={syncMutation.isPending}
                error={apiErrorMessage(syncMutation.error)}
              />
              {syncOk && <p className="mt-2 text-sm text-jade-600 dark:text-jade-400 font-medium">{syncOk}</p>}
            </div>
          )}

          {wallet.faucetEnabled && (
            <div className="mt-5 mh-divider" />
          )}
          {wallet.faucetEnabled && (
            <div className="mt-5">
              <p className="mb-1 flex items-center gap-1.5 text-sm font-medium text-foreground">
                <Sparkles className="h-4 w-4 text-jade-500" /> {t("receive.faucet.title")}
              </p>
              <p className="mb-3 text-xs text-muted-foreground">
                {t("receive.faucet.description")}
              </p>
              <AmountForm 
                onSubmit={(amountCents) => {
                  setDepositOk(null);
                  depositMutation.mutate({ data: { amountCents } }, {
                    onSuccess: () => {
                      queryClient.invalidateQueries({ queryKey: getGetWalletQueryKey() });
                      queryClient.invalidateQueries({ queryKey: getGetDashboardSummaryQueryKey() });
                      setDepositOk(t("receive.faucet.success"));
                    }
                  });
                }}
                presets={[10000, 25000, 50000]} 
                submitLabel={t("receive.faucet.submit")} 
                pending={depositMutation.isPending}
                error={apiErrorMessage(depositMutation.error)}
                ok={depositOk}
              />
            </div>
          )}
        </GlassCard>

        {/* withdraw */}
        <GlassCard>
          <div className="flex items-center gap-3">
            <span className="flex h-11 w-11 items-center justify-center rounded-2xl bg-muted text-foreground">
              <ArrowUpRight className="h-5 w-5" />
            </span>
            <div>
              <h2 className="font-display text-lg font-bold text-foreground">{t("withdraw.title")}</h2>
              <p className="text-xs text-muted-foreground">{t("withdraw.subtitle")}</p>
            </div>
          </div>
          <div className="mt-5">
            {isPrivyCustody ? (
              isWeb3Enabled ? (
                <PrivyWithdrawForm
                  usdcAddress={wallet.usdcAddress ?? null}
                  onSuccess={() => {
                    queryClient.invalidateQueries({ queryKey: getGetWalletQueryKey() });
                    queryClient.invalidateQueries({ queryKey: getGetDashboardSummaryQueryKey() });
                  }}
                />
              ) : (
                <p className="text-sm text-muted-foreground">
                  {t("withdraw.unavailable")}
                </p>
              )
            ) : (
              <WithdrawForm
                onSubmit={async (data) => {
                  setWithdrawOk(null);
                  // Withdrawals send funds to an address you choose — confirm
                  // it's really you before we move anything.
                  const proof = await requestProof();
                  if (!proof) return;
                  withdrawMutation.mutate({ data: { ...data, ...proof } }, {
                    onSuccess: () => {
                      queryClient.invalidateQueries({ queryKey: getGetWalletQueryKey() });
                      queryClient.invalidateQueries({ queryKey: getGetDashboardSummaryQueryKey() });
                      setWithdrawOk(t("withdraw.success"));
                    }
                  });
                }}
                pending={withdrawMutation.isPending}
                error={apiErrorMessage(withdrawMutation.error)}
                ok={withdrawOk}
              />
            )}
          </div>
          {!isPrivyCustody && stepUpDialog}
        </GlassCard>
      </div>

      <GlassCard className="flex items-start gap-3">
        <span className="mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-2xl bg-jade-50 text-jade-600 dark:bg-jade-500/15 dark:text-jade-300">
          <ShieldCheck className="h-5 w-5" />
        </span>
        <p className="text-sm text-muted-foreground">
          {t("footer.settle")}{" "}
          {isPrivyCustody ? t("footer.selfCustody") : t("footer.stepUp")}{" "}
          <StatusPill tone="jade" className="ms-1">{t("footer.builtOnMonad")}</StatusPill>
        </p>
      </GlassCard>
    </div>
  );
}
