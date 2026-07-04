import { useRef, useState } from "react";
import { usePrivy, useLogin, useWallets } from "@privy-io/react-auth";
import { createWalletClient, custom, isAddress } from "viem";
import { monadTestnet } from "viem/chains";
import { Button } from "@/components/ui";
import { WithdrawForm } from "@/components/app/forms";
import { ERC20_ABI } from "@/lib/onchain/abis";
import { centsToUnits } from "@/lib/onchain/ids";
import { useEnsureWalletGas, useConfirmWithdrawal } from "@workspace/api-client-react";
import { apiErrorMessage } from "@/lib/utils";

/**
 * Withdrawal UI for a NON-CUSTODIAL (Privy embedded EOA) wallet. Unlike the
 * server-custody path, the platform holds no key and never signs: the user signs
 * the USDC transfer themselves inside Privy, and the backend only CONFIRMS the
 * broadcast tx (verifying the on-chain receipt) so it can record the withdrawal.
 *
 * Flow: ensure the embedded EOA has gas (MON) -> user signs the ERC-20 transfer
 * over Privy's provider -> POST the tx hash to /wallet/withdraw/submitted. There
 * is no step-up dialog here — the Privy signature IS the authorization.
 */
export function PrivyWithdrawForm({
  usdcAddress,
  onSuccess,
}: {
  usdcAddress: string | null;
  onSuccess: () => void;
}) {
  const { ready, authenticated } = usePrivy();
  const { login } = useLogin();
  const { wallets } = useWallets();
  const ensureGas = useEnsureWalletGas();
  const confirm = useConfirmWithdrawal();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [ok, setOk] = useState<string | null>(null);
  // Holds a just-broadcast tx so an identical retry re-confirms it instead of
  // signing (and paying for) a SECOND on-chain transfer.
  const pendingTx = useRef<{ txHash: `0x${string}`; amountCents: number; destination: string } | null>(null);

  const embedded = wallets.find((w) => w.walletClientType === "privy");

  if (!ready) {
    return <p className="text-sm text-muted-foreground">Loading your wallet…</p>;
  }

  // The app session and the Privy session are separate: a returning user may be
  // signed into MoolaHub but not into Privy in this browser. They must connect
  // Privy to sign, since only they hold the key.
  if (!authenticated || !embedded) {
    return (
      <div className="space-y-3">
        <p className="text-sm text-muted-foreground">
          Your wallet is self-custodial — connect it to sign the withdrawal yourself.
        </p>
        <Button variant="secondary" className="w-full" onClick={() => login()}>
          Connect wallet to withdraw
        </Button>
      </div>
    );
  }

  const handleSubmit = async (data: { destination: string; amountCents: number }) => {
    setError(null);
    setOk(null);
    if (!usdcAddress) {
      setError("On-chain withdrawals aren't available on this deployment.");
      return;
    }
    if (!isAddress(data.destination)) {
      setError("Enter a valid Monad address (starts with 0x).");
      return;
    }
    if (data.amountCents <= 0) {
      setError("Enter a valid amount.");
      return;
    }
    setPending(true);
    try {
      // Reuse an already-broadcast tx for an identical retry so a failed confirm
      // never triggers a SECOND real on-chain send.
      const reused =
        pendingTx.current &&
        pendingTx.current.amountCents === data.amountCents &&
        pendingTx.current.destination.toLowerCase() === data.destination.toLowerCase()
          ? pendingTx.current.txHash
          : null;

      let txHash = reused;
      if (!txHash) {
        // Gas top-up is best-effort: the EOA may already hold MON, or today's
        // top-up cap may be reached. Neither should abort a withdrawal the user
        // can already pay for — if gas is truly missing, the sign below fails
        // with a clear wallet error.
        try {
          await ensureGas.mutateAsync();
        } catch {
          /* non-fatal */
        }
        // Sign + broadcast the USDC transfer from the user's own wallet.
        await embedded.switchChain(monadTestnet.id);
        const provider = await embedded.getEthereumProvider();
        const walletClient = createWalletClient({
          account: embedded.address as `0x${string}`,
          chain: monadTestnet,
          transport: custom(provider),
        });
        txHash = await walletClient.writeContract({
          address: usdcAddress as `0x${string}`,
          abi: ERC20_ABI,
          functionName: "transfer",
          args: [data.destination as `0x${string}`, centsToUnits(data.amountCents)],
        });
        // Persist BEFORE confirming so a confirm failure retries confirm-only.
        pendingTx.current = { txHash, amountCents: data.amountCents, destination: data.destination };
      }

      // Record it server-side: the backend verifies the on-chain receipt, then
      // books the withdrawal to the ledger.
      try {
        await confirm.mutateAsync({
          data: { txHash, amountCents: data.amountCents, destination: data.destination },
        });
      } catch (confirmErr) {
        // The tx is already on-chain. If the SERVER evaluated and rejected it
        // (e.g. it reverted, so nothing left the wallet), drop the stored hash so
        // the user can sign afresh. On a transient network error, keep it so a
        // retry only re-confirms — never re-sends.
        if (typeof (confirmErr as { status?: unknown })?.status === "number") {
          pendingTx.current = null;
        }
        throw confirmErr;
      }

      pendingTx.current = null;
      setOk("Withdrawal sent");
      onSuccess();
    } catch (e) {
      setError(
        apiErrorMessage(e) ??
          (e instanceof Error ? e.message : "Withdrawal failed. Please try again."),
      );
    } finally {
      setPending(false);
    }
  };

  return <WithdrawForm onSubmit={handleSubmit} pending={pending} error={error} ok={ok} />;
}
