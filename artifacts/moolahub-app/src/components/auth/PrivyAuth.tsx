import { PrivyProvider, usePrivy, useLogin as usePrivyLoginHook } from "@privy-io/react-auth";
import { useLocation } from "wouter";
import { useState } from "react";
import { Button } from "@/components/ui";
import { usePrivyAuth, getGetMeQueryKey } from "@workspace/api-client-react";
import { useQueryClient } from "@tanstack/react-query";

function PrivyLoginButton() {
  const [, setLocation] = useLocation();
  const { getAccessToken } = usePrivy();
  const privyAuthMutation = usePrivyAuth();
  const queryClient = useQueryClient();
  const [busy, setBusy] = useState(false);

  const { login } = usePrivyLoginHook({
    onComplete: async () => {
      setBusy(true);
      try {
        const token = await getAccessToken();
        if (token) {
          privyAuthMutation.mutate({ data: { token } }, {
            onSuccess: () => {
              queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() });
              setLocation("/");
            },
            onSettled: () => setBusy(false)
          });
        }
      } catch {
        setBusy(false);
      }
    },
    onError: () => setBusy(false)
  });

  return (
    <Button onClick={() => login()} size="lg" className="w-full" disabled={busy || privyAuthMutation.isPending}>
      {busy || privyAuthMutation.isPending ? "Signing in…" : "Continue with Privy"}
    </Button>
  );
}

export function PrivyAuth({ appId }: { appId: string }) {
  return (
    <PrivyProvider
      appId={appId}
      config={{
        appearance: { 
          theme: "light", 
          accentColor: "#0E9E6E", 
          logo: `${import.meta.env.BASE_URL}brand/moolahub_app_icon.png` 
        },
      }}
    >
      <PrivyLoginButton />
    </PrivyProvider>
  );
}
