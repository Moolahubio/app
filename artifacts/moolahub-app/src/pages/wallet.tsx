import { ArrowDownLeft, ArrowUpRight, Wallet as WalletIcon, ShieldCheck, Sparkles, Clock } from "lucide-react";
import { Card, Badge } from "@/components/ui";
import { PageHeader } from "@/components/app/bits";
import { AmountForm, WithdrawForm, CopyButton, ActionButton } from "@/components/app/forms";
import { useGetWallet, useDepositFaucet, useWithdrawFunds, useSyncDeposits, getGetWalletQueryKey, getGetDashboardSummaryQueryKey } from "@workspace/api-client-react";
import { formatMoney, apiErrorMessage } from "@/lib/utils";
import { useQueryClient } from "@tanstack/react-query";
import { useState } from "react";

const NETWORK = import.meta.env.VITE_BASE_NETWORK === "mainnet" ? "Base" : "Base Sepolia";

export default function WalletPage() {
  const { data: wallet, isLoading } = useGetWallet();

  const queryClient = useQueryClient();
  const depositMutation = useDepositFaucet();
  const withdrawMutation = useWithdrawFunds();
  const syncMutation = useSyncDeposits();

  const [depositOk, setDepositOk] = useState<string | null>(null);
  const [withdrawOk, setWithdrawOk] = useState<string | null>(null);
  const [syncOk, setSyncOk] = useState<string | null>(null);

  if (isLoading || !wallet) {
    return <div className="p-8 text-center text-muted-foreground">Loading wallet...</div>;
  }

  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <PageHeader
        eyebrow="Wallet"
        title="Deposit & withdraw USDC"
        description="MoolaHub runs on USDC over Base. Receive crypto into your wallet, or send it to any Base address."
      />

      {/* balance + receive address */}
      <Card className="relative isolate overflow-hidden border-0 bg-ink-950 p-6 text-white lg:p-8">
        <div className="absolute inset-0 -z-10 bg-grid-dark [background-size:32px_32px] [mask-image:radial-gradient(70%_80%_at_90%_0%,black,transparent)]" />
        <div className="flex items-center justify-between">
          <p className="font-mono text-[10px] uppercase tracking-[0.2em] text-white/45">
            Available balance
          </p>
          <Badge tone="jade" className="bg-jade-500/15 text-jade-300 ring-jade-400/20">
            {NETWORK}
          </Badge>
        </div>
        <p className="mt-1.5 font-display text-4xl font-bold">
          {formatMoney(wallet.availableCents)}
        </p>
        <p className="mt-1 text-sm text-white/55">
          {formatMoney(wallet.goalAllocatedCents)} allocated to goals
        </p>

        {wallet.address && (
          <div className="mt-5 rounded-2xl border border-white/10 bg-white/[0.03] p-4">
            <div className="flex items-center gap-2">
              <WalletIcon className="h-4 w-4 text-jade-400" />
              <p className="font-mono text-[10px] uppercase tracking-[0.18em] text-white/45">
                Your USDC deposit address
              </p>
            </div>
            <div className="mt-2 flex items-center justify-between gap-3">
              <code className="truncate font-mono text-sm text-white/80">{wallet.address}</code>
              <CopyButton value={wallet.address} />
            </div>
            <p className="mt-2 text-xs text-white/45">
              Send only <span className="text-white/70">USDC on {NETWORK}</span> to this address.
            </p>
          </div>
        )}
      </Card>

      <div className="grid gap-6 md:grid-cols-2">
        {/* receive */}
        <Card className="p-6">
          <div className="flex items-center gap-3">
            <span className="flex h-11 w-11 items-center justify-center rounded-2xl bg-jade-50 text-jade-600 dark:bg-jade-500/15 dark:text-jade-300">
              <ArrowDownLeft className="h-5 w-5" />
            </span>
            <div>
              <h2 className="font-display text-lg font-bold text-foreground">Receive</h2>
              <p className="text-xs text-muted-foreground">Deposit USDC on-chain</p>
            </div>
          </div>

          <p className="mt-4 text-sm text-muted-foreground">
            Send USDC to your address above from any Base wallet, then check for it:
          </p>
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
                        ? `Credited ${res.credited} deposit${res.credited === 1 ? "" : "s"} totaling ${formatMoney(res.totalCents ?? 0)}`
                        : "No new deposits found",
                    );
                  }
                });
              }}
              label="Check for deposits"
              pendingLabel="Checking…"
              variant="secondary"
              className="w-full [&>button]:w-full"
              pending={syncMutation.isPending}
              error={apiErrorMessage(syncMutation.error)}
            />
            {syncOk && <p className="mt-2 text-sm text-jade-600 dark:text-jade-400 font-medium">{syncOk}</p>}
          </div>

          <div className="mt-5 border-t border-border pt-5">
            <p className="mb-1 flex items-center gap-1.5 text-sm font-medium text-foreground">
              <Sparkles className="h-4 w-4 text-jade-500" /> Testnet faucet
            </p>
            <p className="mb-3 text-xs text-muted-foreground">
              Grab test USDC to try things out before real funds.
            </p>
            <AmountForm 
              onSubmit={(amountCents) => {
                setDepositOk(null);
                depositMutation.mutate({ data: { amountCents } }, {
                  onSuccess: () => {
                    queryClient.invalidateQueries({ queryKey: getGetWalletQueryKey() });
                    queryClient.invalidateQueries({ queryKey: getGetDashboardSummaryQueryKey() });
                    setDepositOk("Test USDC received");
                  }
                });
              }}
              presets={[10000, 25000, 50000]} 
              submitLabel="Receive test USDC" 
              pending={depositMutation.isPending}
              error={apiErrorMessage(depositMutation.error)}
              ok={depositOk}
            />
          </div>
        </Card>

        {/* withdraw */}
        <Card className="p-6">
          <div className="flex items-center gap-3">
            <span className="flex h-11 w-11 items-center justify-center rounded-2xl bg-muted text-foreground">
              <ArrowUpRight className="h-5 w-5" />
            </span>
            <div>
              <h2 className="font-display text-lg font-bold text-foreground">Withdraw</h2>
              <p className="text-xs text-muted-foreground">Send USDC to any Base address</p>
            </div>
          </div>
          <div className="mt-5">
            <WithdrawForm 
              onSubmit={(data) => {
                setWithdrawOk(null);
                withdrawMutation.mutate({ data }, {
                  onSuccess: () => {
                    queryClient.invalidateQueries({ queryKey: getGetWalletQueryKey() });
                    queryClient.invalidateQueries({ queryKey: getGetDashboardSummaryQueryKey() });
                    setWithdrawOk("Withdrawal successful");
                  }
                });
              }}
              pending={withdrawMutation.isPending}
              error={apiErrorMessage(withdrawMutation.error)}
              ok={withdrawOk}
            />
          </div>
        </Card>
      </div>

      <Card className="flex items-start gap-3 border-jade-500/15 bg-jade-50/60 p-5">
        <ShieldCheck className="mt-0.5 h-5 w-5 shrink-0 text-jade-600" />
        <p className="text-sm text-muted-foreground">
          MoolaHub is non-custodial — funds settle to your own Base wallet, and every movement
          is recorded on the ledger with an on-chain reference.{" "}
          <Badge tone="jade" className="ml-1">Built on Base</Badge>
        </p>
      </Card>

      <Card className="flex items-start gap-3 border-border bg-card p-5">
        <Clock className="mt-0.5 h-5 w-5 shrink-0 text-muted-foreground" />
        <p className="text-sm text-muted-foreground">
          <span className="font-semibold text-foreground">Local currency (GHS · NGN) is coming soon.</span>{" "}
          Cash deposits and withdrawals via a licensed on/off-ramp partner will arrive in a later
          release. For now, MoolaHub runs entirely on USDC.
        </p>
      </Card>
    </div>
  );
}
