"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { useAccount, useConnect, useSignMessage } from "wagmi";
import { AlertCircle } from "lucide-react";
import { Button } from "@/components/ui";

/**
 * "Continue with Base" — connects a Coinbase Smart Wallet (passkey), signs a
 * nonce challenge, and posts it to /api/auth/base which verifies the signature
 * (ERC-1271/6492 for smart accounts) and issues a MoolaHub session.
 */
export function SignInWithBase() {
  const { connectAsync, connectors } = useConnect();
  const { address, isConnected } = useAccount();
  const { signMessageAsync } = useSignMessage();
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();

  async function signIn() {
    setBusy(true);
    setError(undefined);
    try {
      let addr = address;
      if (!isConnected) {
        const res = await connectAsync({ connector: connectors[0] });
        addr = res.accounts[0];
      }
      if (!addr) throw new Error("No Base Account connected.");

      const { nonce } = await (await fetch("/api/auth/base")).json();
      const message = `MoolaHub wants you to sign in with your Base Account.\nAddress: ${addr}\nNonce: ${nonce}`;
      const signature = await signMessageAsync({ message });

      const res = await fetch("/api/auth/base", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ address: addr, message, signature }),
      });
      if (res.ok) {
        router.push("/");
        router.refresh();
      } else {
        setError((await res.json()).error ?? "Sign-in failed.");
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : "Sign-in failed.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div>
      <Button onClick={signIn} disabled={busy} size="lg" className="w-full">
        {busy ? "Connecting…" : "Continue with Base"}
      </Button>
      {error && (
        <p className="mt-2 flex items-center gap-1.5 text-sm text-red-600">
          <AlertCircle className="h-4 w-4" /> {error}
        </p>
      )}
    </div>
  );
}
