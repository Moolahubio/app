"use client";

import { useState } from "react";
import { useAccount, useConnect, useSendCalls } from "wagmi";
import { encodeFunctionData, getAddress, parseAbi, type Hex } from "viem";
import { AlertCircle, CheckCircle2 } from "lucide-react";
import { Button } from "@/components/ui";
import { PAYMASTER_PROXY_URL, BASE_CHAIN } from "@/lib/base/wagmi";
import { recordWithdrawalAction } from "@/app/(app)/actions";

const ERC20 = parseAbi(["function transfer(address to, uint256 amount) returns (bool)"]);
const USDC = (process.env.NEXT_PUBLIC_USDC_ADDRESS ||
  "0x036CbD53842c5426634e7929541eC2318f3dCF7e") as `0x${string}`;

function centsToUnits(cents: number): bigint {
  return BigInt(Math.round(cents)) * 10_000n; // USDC 6dp
}

/**
 * Gasless USDC withdrawal from the user's Base Account: an EIP-5792 sponsored
 * UserOp (paymaster proxied via /api/paymaster). On success the ledger is
 * debited via recordWithdrawalAction. The user pays no gas.
 */
export function BaseWithdraw() {
  const { isConnected } = useAccount();
  const { connectAsync, connectors } = useConnect();
  const { sendCallsAsync } = useSendCalls();
  const [dest, setDest] = useState("");
  const [amount, setAmount] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok?: boolean; error?: string }>({});

  async function withdraw() {
    setBusy(true);
    setMsg({});
    try {
      if (!isConnected) await connectAsync({ connector: connectors[0] });
      const amountCents = Math.round(Number(amount) * 100);
      if (!Number.isFinite(amountCents) || amountCents <= 0) throw new Error("Enter a valid amount.");
      const to = getAddress(dest); // throws if invalid

      const data = encodeFunctionData({
        abi: ERC20,
        functionName: "transfer",
        args: [to, centsToUnits(amountCents)],
      });

      const result = await sendCallsAsync({
        chainId: BASE_CHAIN.id,
        calls: [{ to: USDC, data: data as Hex }],
        capabilities: { paymasterService: { url: PAYMASTER_PROXY_URL } },
      });
      // EIP-5792 returns a bundle id; the indexed tx hash is resolved via
      // useCallsStatus on the live network. We record the id as the reference.
      const ref = typeof result === "string" ? result : (result?.id ?? "");
      const res = await recordWithdrawalAction(amountCents, to, ref);
      if (res.error) setMsg({ error: res.error });
      else setMsg({ ok: true });
    } catch (e) {
      setMsg({ error: e instanceof Error ? e.message : "Withdrawal failed." });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-3">
      <input
        value={dest}
        onChange={(e) => setDest(e.target.value)}
        placeholder="Recipient Base address (0x…)"
        className="h-12 w-full rounded-2xl border border-ink-900/10 bg-white px-4 font-mono text-sm text-ink-900 outline-none focus:ring-2 focus:ring-jade-500/40"
      />
      <div className="flex items-center rounded-2xl border border-ink-900/10 bg-white px-4 focus-within:ring-2 focus-within:ring-jade-500/40">
        <input
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          inputMode="decimal"
          placeholder="0.00"
          className="h-12 w-full bg-transparent text-lg font-semibold text-ink-900 outline-none placeholder:text-ink-300"
        />
        <span className="font-mono text-xs uppercase tracking-[0.15em] text-ink-400">USDC</span>
      </div>
      {msg.error && (
        <p className="flex items-center gap-1.5 text-sm text-red-600">
          <AlertCircle className="h-4 w-4" /> {msg.error}
        </p>
      )}
      {msg.ok && (
        <p className="flex items-center gap-1.5 text-sm text-jade-600">
          <CheckCircle2 className="h-4 w-4" /> Sent gas-free via your Base Account.
        </p>
      )}
      <Button onClick={withdraw} disabled={busy} variant="secondary" className="w-full">
        {busy ? "Sending…" : "Withdraw USDC · gasless"}
      </Button>
      <p className="text-center text-[11px] text-ink-400">Gas sponsored — you pay nothing.</p>
    </div>
  );
}
