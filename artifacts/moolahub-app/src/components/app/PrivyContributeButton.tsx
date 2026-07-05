import { useRef, useState } from "react";
import { usePrivy, useLogin, useWallets } from "@privy-io/react-auth";
import { createPublicClient, createWalletClient, custom } from "viem";
import { monadTestnet } from "viem/chains";
import { AlertCircle } from "lucide-react";
import { Button } from "@/components/ui";
import { ERC20_ABI, CIRCLE_ABI } from "@/lib/onchain/abis";
import { centsToUnits } from "@/lib/onchain/ids";
import { useEnsureWalletGas, useConfirmContribution } from "@workspace/api-client-react";
import { apiErrorMessage } from "@/lib/utils";
import { useTranslation } from "react-i18next";

/**
 * On-chain contribution for a NON-CUSTODIAL (Privy embedded EOA) member. The
 * platform holds no key and never signs: the user signs the contribution
 * themselves inside Privy, and the backend only CONFIRMS the broadcast tx
 * (verifying the on-chain receipt) before booking the ledger contribution. No
 * step-up dialog — the Privy signature IS the authorization.
 *
 * Routing mirrors the server-signed path: rotation circles contribute to the
 * circle's escrow (approve → contribute()); accumulation circles send a plain
 * USDC transfer to the platform-custody address. Server-custody members keep
 * the server-signed contribute path; this button only renders for `custody ===
 * "privy"`.
 */
export function PrivyContributeButton({
  circleId,
  escrow,
  isAccumulation,
  platform,
  usdcAddress,
  contributionCents,
  label,
  onSuccess,
}: {
  circleId: string;
  escrow: string | null;
  isAccumulation: boolean;
  platform: string | null;
  usdcAddress: string | null;
  contributionCents: number;
  label: string;
  onSuccess: () => void;
}) {
  const { t } = useTranslation("circles");
  const { ready, authenticated } = usePrivy();
  const { login } = useLogin();
  const { wallets } = useWallets();
  const ensureGas = useEnsureWalletGas();
  const confirm = useConfirmContribution();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Holds a just-broadcast contribution so an identical retry re-confirms it
  // instead of signing (and paying for) a SECOND on-chain contribution.
  const pendingTx = useRef<`0x${string}` | null>(null);

  const embedded = wallets.find((w) => w.walletClientType === "privy");
  const destination = isAccumulation ? platform : escrow;

  if (!ready) {
    return <p className="text-sm text-white/70">{t("privy.loadingWallet")}</p>;
  }
  if (!authenticated || !embedded) {
    return (
      <div className="space-y-2">
        <p className="text-sm text-white/70">
          {t("privy.selfCustody")}
        </p>
        <Button variant="secondary" size="sm" onClick={() => login()}>
          {t("privy.connect")}
        </Button>
      </div>
    );
  }

  const handleClick = async () => {
    setError(null);
    if (!usdcAddress || !destination) {
      setError(t("privy.notAvailable"));
      return;
    }
    setPending(true);
    try {
      let txHash = pendingTx.current;
      if (!txHash) {
        // Gas top-up is best-effort: the EOA may already hold MON, or today's cap
        // may be reached. If gas is truly missing, the sign below fails loudly.
        try {
          await ensureGas.mutateAsync();
        } catch {
          /* non-fatal */
        }
        await embedded.switchChain(monadTestnet.id);
        const provider = await embedded.getEthereumProvider();
        const owner = embedded.address as `0x${string}`;
        const walletClient = createWalletClient({
          account: owner,
          chain: monadTestnet,
          transport: custom(provider),
        });
        const publicClient = createPublicClient({
          chain: monadTestnet,
          transport: custom(provider),
        });
        const units = centsToUnits(contributionCents);

        if (isAccumulation) {
          // Accumulation: a plain USDC transfer to the platform-custody address
          // that later funds this member's own payout.
          txHash = await walletClient.writeContract({
            address: usdcAddress as `0x${string}`,
            abi: ERC20_ABI,
            functionName: "transfer",
            args: [destination as `0x${string}`, units],
          });
        } else {
          // Rotation: the escrow pulls funds via transferFrom, so approve it
          // first when the allowance is short, then call contribute().
          const allowance = (await publicClient.readContract({
            address: usdcAddress as `0x${string}`,
            abi: ERC20_ABI,
            functionName: "allowance",
            args: [owner, destination as `0x${string}`],
          })) as bigint;
          if (allowance < units) {
            const approveHash = await walletClient.writeContract({
              address: usdcAddress as `0x${string}`,
              abi: ERC20_ABI,
              functionName: "approve",
              args: [destination as `0x${string}`, units],
            });
            await publicClient.waitForTransactionReceipt({ hash: approveHash });
          }
          txHash = await walletClient.writeContract({
            address: destination as `0x${string}`,
            abi: CIRCLE_ABI,
            functionName: "contribute",
          });
        }
        // Persist BEFORE confirming so a confirm failure retries confirm-only.
        pendingTx.current = txHash;
      }

      try {
        await confirm.mutateAsync({ id: circleId, data: { txHash } });
      } catch (confirmErr) {
        // The tx is already on-chain. If the SERVER evaluated and rejected it,
        // drop the stored hash so the user can sign afresh. On a transient
        // network error, keep it so a retry only re-confirms — never re-sends.
        if (typeof (confirmErr as { status?: unknown })?.status === "number") {
          pendingTx.current = null;
        }
        throw confirmErr;
      }

      pendingTx.current = null;
      onSuccess();
    } catch (e) {
      setError(
        apiErrorMessage(e) ??
          (e instanceof Error ? e.message : t("privy.failed")),
      );
    } finally {
      setPending(false);
    }
  };

  return (
    <div className="inline-flex flex-col gap-2">
      <Button type="button" onClick={handleClick} size="sm" disabled={pending}>
        {pending ? t("privy.submitting") : label}
      </Button>
      {error && (
        <span className="flex items-center gap-1.5 text-sm text-rose-300">
          <AlertCircle className="h-4 w-4" /> {error}
        </span>
      )}
    </div>
  );
}
