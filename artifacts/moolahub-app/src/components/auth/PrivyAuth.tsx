import { PrivyProvider, usePrivy, useLogin as usePrivyLoginHook } from "@privy-io/react-auth";
import { useLocation } from "wouter";
import { useRef, useState } from "react";
import { Button } from "@/components/ui";
import { usePrivyAuth, getGetMeQueryKey } from "@workspace/api-client-react";
import { useQueryClient } from "@tanstack/react-query";
import { useTheme } from "@/hooks/use-theme";

function PrivyLoginButton() {
  const [, setLocation] = useLocation();
  const { getAccessToken, authenticated } = usePrivy();
  const privyAuthMutation = usePrivyAuth();
  const queryClient = useQueryClient();
  const [busy, setBusy] = useState(false);
  const [rememberMe, setRememberMe] = useState(false);
  // Tracks whether the user *intentionally* triggered a login. Privy fires
  // `onComplete` both on an explicit login AND when it silently restores a
  // persisted session on mount — without this guard, signing out (which drops
  // only our server session, not Privy's) would auto re-create a server session
  // and bounce the user straight back in.
  const intentionalRef = useRef(false);

  const authenticateWithServer = async () => {
    setBusy(true);
    try {
      const token = await getAccessToken();
      if (token) {
        privyAuthMutation.mutate(
          { data: { token, rememberMe } },
          {
            onSuccess: () => {
              queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() });
              setLocation("/");
            },
            onSettled: () => setBusy(false),
          },
        );
      } else {
        setBusy(false);
      }
    } catch {
      setBusy(false);
    }
  };

  const { login } = usePrivyLoginHook({
    onComplete: () => {
      if (!intentionalRef.current) return;
      intentionalRef.current = false;
      authenticateWithServer();
    },
    onError: () => {
      intentionalRef.current = false;
      setBusy(false);
    },
  });

  const handleClick = () => {
    if (authenticated) {
      // Privy already holds a session (e.g. restored after a server-side sign
      // out). `login()` won't re-open the modal or re-fire onComplete, so go
      // straight to the server exchange.
      authenticateWithServer();
    } else {
      intentionalRef.current = true;
      login();
    }
  };

  return (
    <div className="flex w-full flex-col gap-3">
      <label className="flex items-center gap-2 text-sm text-muted-foreground">
        <input
          type="checkbox"
          checked={rememberMe}
          onChange={(e) => setRememberMe(e.target.checked)}
          className="h-4 w-4 rounded border-border"
        />
        Keep me logged in for 30 days
      </label>
      <Button onClick={handleClick} size="lg" className="w-full" disabled={busy || privyAuthMutation.isPending}>
        {busy || privyAuthMutation.isPending ? "Signing in…" : "Continue with Privy"}
      </Button>
    </div>
  );
}

export function PrivyAuth({ appId }: { appId: string }) {
  const { resolvedTheme } = useTheme();
  return (
    <PrivyProvider
      appId={appId}
      config={{
        appearance: { 
          theme: resolvedTheme, 
          accentColor: "#0E9E6E", 
          logo: `${import.meta.env.BASE_URL}brand/moolahub_app_icon.png` 
        },
      }}
    >
      <PrivyLoginButton />
    </PrivyProvider>
  );
}
