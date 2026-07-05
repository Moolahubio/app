import { useRef, useState } from "react";
import { usePrivy, useLogin, useWallets } from "@privy-io/react-auth";
import { createPublicClient, createWalletClient, custom } from "viem";
import { monadTestnet } from "viem/chains";
import { Button } from "@/components/ui";
import { AmountForm } from "@/components/app/forms";
import { ERC20_ABI, GOAL_VAULT_ABI } from "@/lib/onchain/abis";
import { centsToUnits, idToBytes32 } from "@/lib/onchain/ids";
import {
  useEnsureWalletGas,
  useConfirmGoalDeposit,
  useConfirmGoalRelease,
} from "@workspace/api-client-react";
import type { ReleaseFromGoalResult } from "@workspace/api-client-react";
import { apiErrorMessage } from "@/lib/utils";
import { useTranslation } from "react-i18next";

/**
 * On-chain goal deposit / withdraw UI for a NON-CUSTODIAL (Privy embedded EOA)
 * wallet. The platform holds no key and never signs: the user signs the goal
 * vault deposit/withdraw themselves inside Privy, and the backend only CONFIRMS
 * the broadcast tx (verifying the on-chain receipt) so it can book the ledger
 * move. There is no step-up dialog — the Privy signature IS the authorization.
 *
 * Server-custody wallets keep using the server-signed allocate/release paths;
 * these forms are only rendered when `wallet.custody === "privy"`.
 */

/** Gate shown until the user connects Privy in this browser. */
function ConnectPrompt({ kind, onConnect }: { kind: "deposit" | "withdrawal"; onConnect: () => void }) {
  const { t } = useTranslation("goals");
  return (
    <div className="space-y-3">
      <p className="text-sm text-muted-foreground">
        {t(`privy.connect.${kind}.prompt`)}
      </p>
      <Button variant="secondary" className="w-full" onClick={onConnect}>
        {t(`privy.connect.${kind}.button`)}
      </Button>
    </div>
  );
}

export function PrivyGoalDepositForm({
  goalId,
  goalVault,
  usdcAddress,
  presets,
  onSuccess,
}: {
  goalId: string;
  goalVault: string | null;
  usdcAddress: string | null;
  presets?: number[];
  onSuccess: () => void;
}) {
  const { t } = useTranslation("goals");
  const { ready, authenticated } = usePrivy();
  const { login } = useLogin();
  const { wallets } = useWallets();
  const ensureGas = useEnsureWalletGas();
  const confirm = useConfirmGoalDeposit();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [ok, setOk] = useState<string | null>(null);
  // Holds a just-broadcast deposit so an identical retry re-confirms it instead
  // of signing (and paying for) a SECOND on-chain deposit.
  const pendingTx = useRef<{ txHash: `0x${string}`; amountCents: number } | null>(null);

  const embedded = wallets.find((w) => w.walletClientType === "privy");

  if (!ready) {
    return <p className="text-sm text-muted-foreground">{t("privy.loadingWallet")}</p>;
  }
  if (!authenticated || !embedded) {
    return <ConnectPrompt kind="deposit" onConnect={() => login()} />;
  }

  const handleSubmit = async (amountCents: number) => {
    setError(null);
    setOk(null);
    if (!goalVault || !usdcAddress) {
      setError(t("privy.errors.unavailable"));
      return;
    }
    if (amountCents <= 0) {
      setError(t("privy.errors.invalidAmount"));
      return;
    }
    setPending(true);
    try {
      const reused =
        pendingTx.current && pendingTx.current.amountCents === amountCents
          ? pendingTx.current.txHash
          : null;

      let txHash = reused;
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
        // Reads go over the same Privy connection so we don't depend on a
        // separately-configured RPC URL.
        const publicClient = createPublicClient({
          chain: monadTestnet,
          transport: custom(provider),
        });
        const units = centsToUnits(amountCents);
        // The vault pulls funds via transferFrom, so approve it first when the
        // allowance is short (mirrors the server-signed deposit path).
        const allowance = (await publicClient.readContract({
          address: usdcAddress as `0x${string}`,
          abi: ERC20_ABI,
          functionName: "allowance",
          args: [owner, goalVault as `0x${string}`],
        })) as bigint;
        if (allowance < units) {
          const approveHash = await walletClient.writeContract({
            address: usdcAddress as `0x${string}`,
            abi: ERC20_ABI,
            functionName: "approve",
            args: [goalVault as `0x${string}`, units],
          });
          await publicClient.waitForTransactionReceipt({ hash: approveHash });
        }
        txHash = await walletClient.writeContract({
          address: goalVault as `0x${string}`,
          abi: GOAL_VAULT_ABI,
          functionName: "deposit",
          args: [idToBytes32(goalId), units],
        });
        // Persist BEFORE confirming so a confirm failure retries confirm-only.
        pendingTx.current = { txHash, amountCents };
      }

      try {
        await confirm.mutateAsync({ id: goalId, data: { txHash, amountCents } });
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
      setOk(t("deposit.success"));
      onSuccess();
    } catch (e) {
      setError(
        apiErrorMessage(e) ??
          (e instanceof Error ? e.message : t("privy.errors.depositFailed")),
      );
    } finally {
      setPending(false);
    }
  };

  return (
    <AmountForm
      onSubmit={handleSubmit}
      presets={presets}
      submitLabel={t("deposit.addFunds")}
      pending={pending}
      error={error}
      ok={ok}
    />
  );
}

export function PrivyGoalReleaseForm({
  goalId,
  goalVault,
  onSuccess,
}: {
  goalId: string;
  goalVault: string | null;
  onSuccess: (res: ReleaseFromGoalResult) => void;
}) {
  const { t } = useTranslation("goals");
  const { ready, authenticated } = usePrivy();
  const { login } = useLogin();
  const { wallets } = useWallets();
  const ensureGas = useEnsureWalletGas();
  const confirm = useConfirmGoalRelease();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [ok, setOk] = useState<string | null>(null);
  const pendingTx = useRef<{ txHash: `0x${string}`; amountCents: number } | null>(null);

  const embedded = wallets.find((w) => w.walletClientType === "privy");

  if (!ready) {
    return <p className="text-sm text-muted-foreground">{t("privy.loadingWallet")}</p>;
  }
  if (!authenticated || !embedded) {
    return <ConnectPrompt kind="withdrawal" onConnect={() => login()} />;
  }

  const handleSubmit = async (amountCents: number) => {
    setError(null);
    setOk(null);
    if (!goalVault) {
      setError(t("privy.errors.unavailable"));
      return;
    }
    if (amountCents <= 0) {
      setError(t("privy.errors.invalidAmount"));
      return;
    }
    setPending(true);
    try {
      const reused =
        pendingTx.current && pendingTx.current.amountCents === amountCents
          ? pendingTx.current.txHash
          : null;

      let txHash = reused;
      if (!txHash) {
        try {
          await ensureGas.mutateAsync();
        } catch {
          /* non-fatal */
        }
        await embedded.switchChain(monadTestnet.id);
        const provider = await embedded.getEthereumProvider();
        const walletClient = createWalletClient({
          account: embedded.address as `0x${string}`,
          chain: monadTestnet,
          transport: custom(provider),
        });
        // The vault holds the funds, so a withdraw needs no approval — the vault
        // takes the 2% fee on-chain and returns the net to the user's wallet.
        txHash = await walletClient.writeContract({
          address: goalVault as `0x${string}`,
          abi: GOAL_VAULT_ABI,
          functionName: "withdraw",
          args: [idToBytes32(goalId), centsToUnits(amountCents)],
        });
        pendingTx.current = { txHash, amountCents };
      }

      let result: ReleaseFromGoalResult;
      try {
        result = await confirm.mutateAsync({ id: goalId, data: { txHash, amountCents } });
      } catch (confirmErr) {
        if (typeof (confirmErr as { status?: unknown })?.status === "number") {
          pendingTx.current = null;
        }
        throw confirmErr;
      }

      pendingTx.current = null;
      setOk(null);
      onSuccess(result);
    } catch (e) {
      setError(
        apiErrorMessage(e) ??
          (e instanceof Error ? e.message : t("privy.errors.withdrawalFailed")),
      );
    } finally {
      setPending(false);
    }
  };

  return (
    <AmountForm
      onSubmit={handleSubmit}
      submitLabel={t("withdraw.submit")}
      variant="secondary"
      pending={pending}
      error={error}
      ok={ok}
    />
  );
}
