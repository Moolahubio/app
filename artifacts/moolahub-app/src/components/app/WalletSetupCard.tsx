import { useRef, useState } from "react";
import { usePrivy, useLogin as usePrivyLoginHook } from "@privy-io/react-auth";
import { Wallet, AlertCircle, ShieldCheck } from "lucide-react";
import { Card, Button } from "@/components/ui";
import {
  useLinkPrivy,
  useGetMe,
  getGetMeQueryKey,
  getGetWalletQueryKey,
  getGetDashboardSummaryQueryKey,
} from "@workspace/api-client-react";
import { useQueryClient } from "@tanstack/react-query";
import { isWeb3Enabled } from "@/components/app/Web3Provider";
import { apiErrorMessage } from "@/lib/utils";

const NETWORK = import.meta.env.VITE_CHAIN_NAME ?? "Monad Testnet";

function SetupButton() {
  const { getAccessToken, authenticated } = usePrivy();
  const { data: me } = useGetMe();
  const linkPrivy = useLinkPrivy();
  const queryClient = useQueryClient();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const intentionalRef = useRef(false);

  const provision = async () => {
    setBusy(true);
    setError(null);
    try {
      const token = await getAccessToken();
      if (!token) {
        setBusy(false);
        return;
      }
      // Linking the Privy identity provisions the user's wallet server-side.
      await linkPrivy.mutateAsync({ data: { token } });
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: getGetWalletQueryKey() }),
        queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() }),
        queryClient.invalidateQueries({ queryKey: getGetDashboardSummaryQueryKey() }),
      ]);
    } catch (err) {
      setError(apiErrorMessage(err) ?? "Could not set up your wallet. Please try again.");
    } finally {
      setBusy(false);
    }
  };

  const { login } = usePrivyLoginHook({
    onComplete: () => {
      if (!intentionalRef.current) return;
      intentionalRef.current = false;
      void provision();
    },
    onError: () => {
      intentionalRef.current = false;
      setBusy(false);
    },
  });

  const handleClick = () => {
    setError(null);
    if (authenticated) {
      void provision();
    } else {
      intentionalRef.current = true;
      // Prefill the Privy email with the account email so the wallet is linked
      // to the same email the user registered with (avoids signing up under a
      // different address).
      const email = me?.email?.trim();
      login(email ? { prefill: { type: "email", value: email } } : undefined);
    }
  };

  const pending = busy || linkPrivy.isPending;

  return (
    <div className="text-center">
      <span className="mx-auto flex h-14 w-14 items-center justify-center rounded-2xl bg-jade-50 text-jade-600 dark:bg-jade-500/15 dark:text-jade-300">
        <Wallet className="h-7 w-7" />
      </span>
      <h2 className="mt-4 font-display text-xl font-bold text-foreground">Set up your wallet</h2>
      <p className="mx-auto mt-2 max-w-md text-sm text-muted-foreground">
        Continue with Privy to create your {NETWORK} wallet. Privy lets you sign up with an email
        or connect an existing web3 wallet — either way, you'll be able to deposit, save, and
        withdraw USDC.
      </p>

      <Button className="mt-6" onClick={handleClick} disabled={pending}>
        {pending ? "Setting up…" : "Continue with Privy"}
      </Button>

      {error && (
        <p className="mt-4 flex items-center justify-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
          <AlertCircle className="h-4 w-4 shrink-0" /> {error}
        </p>
      )}

      <p className="mx-auto mt-6 flex max-w-md items-center justify-center gap-1.5 text-xs text-muted-foreground">
        <ShieldCheck className="h-3.5 w-3.5 shrink-0 text-jade-600" />
        Your wallet is yours. Funds settle on Monad and every movement is recorded on the ledger.
      </p>
    </div>
  );
}

export function WalletSetupCard() {
  if (!isWeb3Enabled) {
    return (
      <Card className="p-8 text-center">
        <span className="mx-auto flex h-14 w-14 items-center justify-center rounded-2xl bg-muted text-foreground">
          <Wallet className="h-7 w-7" />
        </span>
        <h2 className="mt-4 font-display text-xl font-bold text-foreground">Wallet setup unavailable</h2>
        <p className="mx-auto mt-2 max-w-md text-sm text-muted-foreground">
          Wallet provisioning isn't configured on this deployment yet. Please check back later.
        </p>
      </Card>
    );
  }

  return (
    <Card className="p-8">
      <SetupButton />
    </Card>
  );
}
