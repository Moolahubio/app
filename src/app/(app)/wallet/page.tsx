import { ArrowDownLeft, ArrowUpRight, Wallet, ShieldCheck, AlertCircle } from "lucide-react";
import { Card, Badge } from "@/components/ui";
import { PageHeader } from "@/components/app/bits";
import { AmountForm, CopyButton } from "@/components/app/forms";
import { requireUser } from "@/lib/server/auth";
import { userBalances } from "@/lib/server/ledger";
import { depositAction, withdrawAction } from "@/app/(app)/actions";
import { formatMoney, truncateAddress } from "@/lib/utils";

export default async function WalletPage() {
  const user = await requireUser();
  const balances = await userBalances(user.id);
  const verified = user.kycStatus === "verified";
  const address = user.wallet?.stellarPublicKey ?? "";

  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <PageHeader
        eyebrow="Wallet"
        title="Add or withdraw money"
        description="Deposit local currency via the fiat rail or move USDC out. Settlement is on Stellar."
      />

      {/* balance + address */}
      <Card className="relative isolate overflow-hidden border-0 bg-ink-950 p-6 text-white lg:p-8">
        <div className="absolute inset-0 -z-10 bg-grid-dark [background-size:32px_32px] [mask-image:radial-gradient(70%_80%_at_90%_0%,black,transparent)]" />
        <div className="absolute -right-10 -top-16 -z-10 h-56 w-56 rounded-full bg-jade-500/20 blur-[90px]" />
        <p className="font-mono text-[10px] uppercase tracking-[0.2em] text-white/45">
          Available balance
        </p>
        <p className="mt-1.5 font-display text-4xl font-bold">
          {formatMoney(balances.availableCents)}
        </p>
        <p className="mt-1 text-sm text-white/55">
          {formatMoney(balances.allocatedCents)} allocated to goals
        </p>
        {address && (
          <div className="mt-5 flex items-center justify-between gap-3 rounded-2xl border border-white/10 bg-white/[0.03] p-3">
            <span className="inline-flex items-center gap-2 font-mono text-xs text-white/70">
              <Wallet className="h-4 w-4 text-jade-400" />
              {truncateAddress(address, 8, 8)}
            </span>
            <CopyButton value={address} />
          </div>
        )}
      </Card>

      <div className="grid gap-6 md:grid-cols-2">
        {/* deposit */}
        <Card className="p-6">
          <div className="flex items-center gap-3">
            <span className="flex h-11 w-11 items-center justify-center rounded-2xl bg-jade-50 text-jade-600">
              <ArrowDownLeft className="h-5 w-5" />
            </span>
            <div>
              <h2 className="font-display text-lg font-bold text-ink-900">Add money</h2>
              <p className="text-xs text-ink-500">Fiat → USDC · fee-free</p>
            </div>
          </div>
          {verified ? (
            <div className="mt-5">
              <AmountForm action={depositAction} presets={[5000, 10000, 25000]} submitLabel="Deposit" />
            </div>
          ) : (
            <div className="mt-5 flex items-start gap-2 rounded-2xl bg-amber-50/70 p-4 text-sm text-ink-600">
              <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-amber-600" />
              <span>
                Identity verification (KYC) is required to deposit local currency. Complete it from
                your <span className="font-semibold">Profile</span>.
              </span>
            </div>
          )}
        </Card>

        {/* withdraw */}
        <Card className="p-6">
          <div className="flex items-center gap-3">
            <span className="flex h-11 w-11 items-center justify-center rounded-2xl bg-ink-900/[0.06] text-ink-700">
              <ArrowUpRight className="h-5 w-5" />
            </span>
            <div>
              <h2 className="font-display text-lg font-bold text-ink-900">Withdraw</h2>
              <p className="text-xs text-ink-500">USDC → local currency</p>
            </div>
          </div>
          <div className="mt-5">
            <AmountForm
              action={withdrawAction}
              presets={[5000, 10000]}
              submitLabel="Withdraw"
              variant="secondary"
            />
          </div>
        </Card>
      </div>

      <Card className="flex items-start gap-3 border-jade-500/15 bg-jade-50/60 p-5">
        <ShieldCheck className="mt-0.5 h-5 w-5 shrink-0 text-jade-600" />
        <p className="text-sm text-ink-600">
          MoolaHub is non-custodial — funds settle to your own Stellar wallet. Every deposit and
          withdrawal is recorded on the ledger with an on-chain reference.{" "}
          <Badge tone="jade" className="ml-1">Built on Stellar</Badge>
        </p>
      </Card>
    </div>
  );
}
