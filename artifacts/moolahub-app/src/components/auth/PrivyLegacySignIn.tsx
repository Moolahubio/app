import { useRef, useState } from "react";
import { PrivyProvider, usePrivy, useLogin as usePrivyLoginHook } from "@privy-io/react-auth";
import { Wallet, AlertCircle } from "lucide-react";
import { useLocation } from "wouter";
import { useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui";
import { usePrivyAuth, getGetMeQueryKey } from "@workspace/api-client-react";
import { useTheme } from "@/hooks/use-theme";
import { apiErrorMessage } from "@/lib/utils";

/**
 * Legacy sign-in path for accounts created before email + password auth.
 *
 * Email + password is the primary way in. This option exists ONLY so that
 * passwordless legacy Privy accounts (no password, no passkey) are not
 * stranded: they can authenticate via Privy once and are then routed through
 * the profile-completion gate to set a username and password. The backend
 * rejects /auth/privy for any account that already has a password, so this can
 * never become a password bypass.
 */
function PrivyLegacyButton({
  onTwoFactorRequired,
}: {
  onTwoFactorRequired: (challengeId: string) => void;
}) {
  const [, setLocation] = useLocation();
  const queryClient = useQueryClient();
  const { getAccessToken, authenticated } = usePrivy();
  const privyAuth = usePrivyAuth();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const intentionalRef = useRef(false);

  const exchange = async () => {
    setBusy(true);
    setError(null);
    try {
      const token = await getAccessToken();
      if (!token) {
        setBusy(false);
        return;
      }
      const result = await privyAuth.mutateAsync({ data: { token } });
      if (result.twoFactorRequired) {
        if (result.challengeId) onTwoFactorRequired(result.challengeId);
        else setError("We couldn't start verification. Please try again.");
        return;
      }
      await queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() });
      setLocation("/");
    } catch (err) {
      setError(apiErrorMessage(err) ?? "We couldn't sign you in with Privy. Please try again.");
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
      <Button
        type="button"
        size="lg"
        variant="secondary"
        className="w-full"
        disabled={busy || privyAuth.isPending}
        onClick={handleClick}
      >
        <Wallet className="h-4 w-4" />
        {busy || privyAuth.isPending ? "Signing in…" : "Sign in with Privy"}
      </Button>

      {error && (
        <p className="mt-3 flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
          <AlertCircle className="h-4 w-4 shrink-0" /> {error}
        </p>
      )}
    </div>
  );
}

export function PrivyLegacySignIn({
  onTwoFactorRequired,
}: {
  onTwoFactorRequired: (challengeId: string) => void;
}) {
  const { resolvedTheme } = useTheme();
  const appId = import.meta.env.VITE_PRIVY_APP_ID;
  const privyReady = Boolean(appId && appId.length >= 10);

  if (!privyReady) return null;

  return (
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
      <PrivyLegacyButton onTwoFactorRequired={onTwoFactorRequired} />
    </PrivyProvider>
  );
}
