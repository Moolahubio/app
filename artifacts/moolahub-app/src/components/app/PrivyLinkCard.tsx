import { useRef, useState } from "react";
import { PrivyProvider, usePrivy, useLogin as usePrivyLoginHook } from "@privy-io/react-auth";
import { Wallet, AlertCircle, Check } from "lucide-react";
import { Card, Button, Badge } from "@/components/ui";
import { useGetMe, useLinkPrivy, getGetMeQueryKey } from "@workspace/api-client-react";
import { useQueryClient } from "@tanstack/react-query";
import { useTheme } from "@/hooks/use-theme";
import { apiErrorMessage } from "@/lib/utils";

function LinkButton() {
  const { data: user } = useGetMe();
  const { getAccessToken, authenticated } = usePrivy();
  const linkPrivy = useLinkPrivy();
  const queryClient = useQueryClient();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const intentionalRef = useRef(false);

  const linked = user?.privyLinked ?? false;

  const exchange = async () => {
    setBusy(true);
    setError(null);
    try {
      const token = await getAccessToken();
      if (!token) {
        setBusy(false);
        return;
      }
      await linkPrivy.mutateAsync({ data: { token } });
      await queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() });
    } catch (err) {
      setError(apiErrorMessage(err) ?? "Could not link your wallet. Please try again.");
    } finally {
      setBusy(false);
    }
  };

  const { login } = usePrivyLoginHook({
    onComplete: () => {
      if (!intentionalRef.current) return;
      intentionalRef.current = false;
      void exchange();
    },
    onError: () => {
      intentionalRef.current = false;
      setBusy(false);
    },
  });

  const handleClick = () => {
    setError(null);
    if (authenticated) {
      void exchange();
    } else {
      intentionalRef.current = true;
      login();
    }
  };

  return (
    <div>
      <div className="flex items-start justify-between gap-3">
        <div className="flex items-center gap-3">
          <span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-muted text-foreground">
            <Wallet className="h-5 w-5" />
          </span>
          <div>
            <div className="flex items-center gap-2">
              <p className="text-sm font-semibold text-foreground">Connect a wallet</p>
              {linked ? <Badge tone="jade">Linked</Badge> : <Badge tone="neutral">Optional</Badge>}
            </div>
            <p className="text-xs text-muted-foreground">
              Link Privy to fund your account from an external wallet
            </p>
          </div>
        </div>
        {!linked && (
          <Button size="sm" variant="secondary" onClick={handleClick} disabled={busy || linkPrivy.isPending}>
            {busy || linkPrivy.isPending ? "Linking…" : "Link Privy"}
          </Button>
        )}
      </div>

      {linked && (
        <p className="mt-4 flex items-center gap-1.5 text-sm text-jade-600 dark:text-jade-400">
          <Check className="h-4 w-4 shrink-0" /> Privy is linked to your account.
        </p>
      )}
      {error && (
        <p className="mt-4 flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
          <AlertCircle className="h-4 w-4 shrink-0" /> {error}
        </p>
      )}
    </div>
  );
}

export function PrivyLinkCard() {
  const { resolvedTheme } = useTheme();
  const appId = import.meta.env.VITE_PRIVY_APP_ID;
  const privyReady = Boolean(appId && appId.length >= 10);

  if (!privyReady) return null;

  return (
    <Card className="p-5">
      <PrivyProvider
        appId={appId}
        config={{
          appearance: {
            theme: resolvedTheme,
            accentColor: "#0E9E6E",
            logo: `${import.meta.env.BASE_URL}brand/moolahub_app_icon.png`,
          },
        }}
      >
        <LinkButton />
      </PrivyProvider>
    </Card>
  );
}
