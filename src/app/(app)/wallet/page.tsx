import { ArrowDownLeft, ArrowUpRight, Wallet, ShieldCheck, Sparkles, RefreshCw, Clock } from "lucide-react";
import { Card, Badge } from "@/components/ui";
import { PageHeader } from "@/components/app/bits";
import { AmountForm, WithdrawForm, CopyButton, ActionButton } from "@/components/app/forms";
import { BaseWalletActions } from "@/components/base/BaseWalletActions";
import { requireUser } from "@/lib/server/auth";
import { userBalances } from "@/lib/server/ledger";
import { depositAction, syncDepositsAction } from "@/app/(app)/actions";
import { formatMoney } from "@/lib/utils";

const NETWORK = process.env.BASE_NETWORK === "mainnet" ? "Base" : "Base Sepolia";

export default async function WalletPage() {
  const user = await requireUser();
  const balances = await userBalances(user.id);
  const address = user.wallet?.address ?? "";

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
        <div className="absolute -right-10 -top-16 -z-10 h-56 w-56 rounded-full bg-jade-500/20 blur-[90px]" />
        <div className="flex items-center justify-between">
          <p className="font-mono text-[10px] uppercase tracking-[0.2em] text-white/45">
            Available balance
          </p>
          <Badge tone="jade" className="bg-jade-500/15 text-jade-300 ring-jade-400/20">
            {NETWORK}
          </Badge>
        </div>
        <p className="mt-1.5 font-display text-4xl font-bold">
          {formatMoney(balances.availableCents)}
        </p>
        <p className="mt-1 text-sm text-white/55">
          {formatMoney(balances.allocatedCents)} allocated to goals
        </p>

        {address && (
          <div className="mt-5 rounded-2xl border border-white/10 bg-white/[0.03] p-4">
            <div className="flex items-center gap-2">
              <Wallet className="h-4 w-4 text-jade-400" />
              <p className="font-mono text-[10px] uppercase tracking-[0.18em] text-white/45">
                Your USDC deposit address
              </p>
            </div>
            <div className="mt-2 flex items-center justify-between gap-3">
              <code className="truncate font-mono text-sm text-white/80">{address}</code>
              <CopyButton value={address} />
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
            <span className="flex h-11 w-11 items-center justify-center rounded-2xl bg-jade-50 text-jade-600">
              <ArrowDownLeft className="h-5 w-5" />
            </span>
            <div>
              <h2 className="font-display text-lg font-bold text-ink-900">Receive</h2>
              <p className="text-xs text-ink-500">Deposit USDC on-chain</p>
            </div>
          </div>

          <p className="mt-4 text-sm text-ink-600">
            Send USDC to your address above from any Base wallet, then check for it:
          </p>
          <div className="mt-3">
            <ActionButton
              action={syncDepositsAction}
              label="Check for deposits"
              pendingLabel="Checking…"
              variant="secondary"
              className="w-full [&>button]:w-full"
            />
          </div>

          <div className="mt-5 border-t border-ink-900/[0.06] pt-5">
            <p className="mb-1 flex items-center gap-1.5 text-sm font-medium text-ink-700">
              <Sparkles className="h-4 w-4 text-jade-500" /> Testnet faucet
            </p>
            <p className="mb-3 text-xs text-ink-500">
              Grab test USDC to try things out before real funds.
            </p>
            <AmountForm action={depositAction} presets={[10000, 25000, 50000]} submitLabel="Receive test USDC" />
          </div>
        </Card>

        {/* withdraw */}
        <Card className="p-6">
          <div className="flex items-center gap-3">
            <span className="flex h-11 w-11 items-center justify-center rounded-2xl bg-ink-900/[0.06] text-ink-700">
              <ArrowUpRight className="h-5 w-5" />
            </span>
            <div>
              <h2 className="font-display text-lg font-bold text-ink-900">Withdraw</h2>
              <p className="text-xs text-ink-500">Send USDC to any Base address</p>
            </div>
          </div>
          <div className="mt-5">
            <WithdrawForm />
            <BaseWalletActions />
          </div>
        </Card>
      </div>

      <Card className="flex items-start gap-3 border-jade-500/15 bg-jade-50/60 p-5">
        <ShieldCheck className="mt-0.5 h-5 w-5 shrink-0 text-jade-600" />
        <p className="text-sm text-ink-600">
          MoolaHub is non-custodial — funds settle to your own Base wallet, and every movement
          is recorded on the ledger with an on-chain reference.{" "}
          <Badge tone="jade" className="ml-1">Built on Base</Badge>
        </p>
      </Card>

      <Card className="flex items-start gap-3 border-ink-900/[0.06] bg-white p-5">
        <Clock className="mt-0.5 h-5 w-5 shrink-0 text-ink-400" />
        <p className="text-sm text-ink-500">
          <span className="font-semibold text-ink-700">Local currency (GHS · NGN) is coming soon.</span>{" "}
          Cash deposits and withdrawals via a licensed on/off-ramp partner will arrive in a later
          release. For now, MoolaHub runs entirely on USDC.
        </p>
      </Card>
    </div>
  );
}
