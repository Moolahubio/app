"use client";

import { PrivyProvider, usePrivy, useLogin } from "@privy-io/react-auth";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { Button } from "@/components/ui";

function PrivyLoginButton() {
  const router = useRouter();
  const { getAccessToken } = usePrivy();
  const [busy, setBusy] = useState(false);

  const { login } = useLogin({
    onComplete: async () => {
      setBusy(true);
      try {
        const token = await getAccessToken();
        const res = await fetch("/api/auth/privy", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ token }),
        });
        if (res.ok) {
          router.push("/");
          router.refresh();
        }
      } finally {
        setBusy(false);
      }
    },
  });

  return (
    <Button onClick={() => login()} size="lg" className="w-full" disabled={busy}>
      {busy ? "Signing in…" : "Continue with Privy"}
    </Button>
  );
}

export function PrivyAuth({ appId }: { appId: string }) {
  return (
    <PrivyProvider
      appId={appId}
      config={{
        appearance: { theme: "light", accentColor: "#0E9E6E", logo: "/brand/moolahub_app_icon.png" },
      }}
    >
      <PrivyLoginButton />
    </PrivyProvider>
  );
}
