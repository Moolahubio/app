import { useRef, useState } from "react";
import {
  usePrivy,
  useLogin as usePrivyLoginHook,
  useWallets,
  useCreateWallet,
} from "@privy-io/react-auth";
import { Wallet, AlertCircle, ShieldCheck } from "lucide-react";
import { useTranslation } from "react-i18next";
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
import { useStepUpGate } from "@/components/app/StepUpDialog";

const NETWORK = import.meta.env.VITE_CHAIN_NAME ?? "Monad Testnet";

function SetupButton() {
  const { t } = useTranslation("wallet");
  const { getAccessToken, authenticated } = usePrivy();
  const { wallets } = useWallets();
  const { createWallet } = useCreateWallet();
  const { data: me } = useGetMe();
  const linkPrivy = useLinkPrivy();
  const queryClient = useQueryClient();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const intentionalRef = useRef(false);
  const { requestProof, stepUpDialog } = useStepUpGate();

  const provision = async () => {
    setBusy(true);
    setError(null);
    try {
      const token = await getAccessToken();
      if (!token) {
        setBusy(false);
        return;
      }
      // This Privy app has embedded-wallet auto-creation ("create on login")
      // disabled, so a freshly logged-in user may have NO embedded EOA. Provision
      // one explicitly before linking — the backend links only when a Privy
      // embedded wallet exists and refuses to fall back to server custody.
      if (!wallets.some((w) => w.walletClientType === "privy")) {
        try {
          await createWallet();
        } catch (createErr) {
          // A wallet may already exist (client wallet state can lag Privy's);
          // linking will find it. A genuine failure surfaces below as a link
          // error ("No Privy embedded wallet found"), but log it so a real
          // creation failure is diagnosable rather than fully silent.
          console.warn("Privy createWallet() failed (continuing to link):", createErr);
        }
      }
      const proof = await requestProof();
      if (!proof) {
        setBusy(false);
        return;
      }
      // Linking the Privy identity provisions the user's wallet server-side.
      await linkPrivy.mutateAsync({ data: { token, ...proof } });
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: getGetWalletQueryKey() }),
        queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() }),
        queryClient.invalidateQueries({ queryKey: getGetDashboardSummaryQueryKey() }),
      ]);
    } catch (err) {
      setError(apiErrorMessage(err) ?? t("setup.error"));
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
      <h2 className="mt-4 font-display text-xl font-bold text-foreground">{t("setup.title")}</h2>
      <p className="mx-auto mt-2 max-w-md text-sm text-muted-foreground">
        {t("setup.description", { network: NETWORK })}
      </p>

      <Button className="mt-6" onClick={handleClick} disabled={pending}>
        {pending ? t("setup.settingUp") : t("setup.continueWithPrivy")}
      </Button>

      {error && (
        <p className="mt-4 flex items-center justify-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
          <AlertCircle className="h-4 w-4 shrink-0" /> {error}
        </p>
      )}

      <p className="mx-auto mt-6 flex max-w-md items-center justify-center gap-1.5 text-xs text-muted-foreground">
        <ShieldCheck className="h-3.5 w-3.5 shrink-0 text-jade-600" />
        {t("setup.securityNote")}
      </p>

      {stepUpDialog}
    </div>
  );
}

export function WalletSetupCard() {
  const { t } = useTranslation("wallet");
  if (!isWeb3Enabled) {
    return (
      <Card className="p-8 text-center">
        <span className="mx-auto flex h-14 w-14 items-center justify-center rounded-2xl bg-muted text-foreground">
          <Wallet className="h-7 w-7" />
        </span>
        <h2 className="mt-4 font-display text-xl font-bold text-foreground">{t("setup.unavailableTitle")}</h2>
        <p className="mx-auto mt-2 max-w-md text-sm text-muted-foreground">
          {t("setup.unavailableDescription")}
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
