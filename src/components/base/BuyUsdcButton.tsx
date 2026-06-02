"use client";

import { useState } from "react";
import { CreditCard, AlertCircle } from "lucide-react";
import { Button } from "@/components/ui";

/**
 * "Buy USDC with card" — asks our server for a Coinbase Onramp session URL
 * (bound to the user's own wallet) and opens the hosted checkout. The purchased
 * USDC lands on-chain in the user's Base wallet; "Check for deposits" then
 * credits the ledger.
 */
export function BuyUsdcButton({ presetFiatAmount = 20 }: { presetFiatAmount?: number }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();

  async function buy() {
    setBusy(true);
    setError(undefined);
    try {
      const res = await fetch("/api/onramp", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ presetFiatAmount }),
      });
      const data = await res.json();
      if (!res.ok || !data.url) {
        setError(data.error ?? "Couldn't start checkout.");
        return;
      }
      window.open(data.url, "_blank", "noopener,noreferrer,width=470,height=720");
    } catch {
      setError("Couldn't start checkout.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div>
      <Button onClick={buy} disabled={busy} className="w-full">
        <CreditCard className="h-4 w-4" />
        {busy ? "Starting…" : "Buy USDC with card"}
      </Button>
      {error && (
        <p className="mt-2 flex items-center gap-1.5 text-sm text-red-600">
          <AlertCircle className="h-4 w-4" /> {error}
        </p>
      )}
      <p className="mt-2 text-center text-[11px] text-ink-400">
        Powered by Coinbase Onramp · funds land in your wallet
      </p>
    </div>
  );
}
