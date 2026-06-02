"use client";

import dynamic from "next/dynamic";
import { baseAccountEnabled } from "@/lib/base/wagmi";

const BaseProviders = dynamic(() => import("./BaseProviders").then((m) => m.BaseProviders), {
  ssr: false,
  loading: () => null,
});
const BaseWithdraw = dynamic(() => import("./BaseWithdraw").then((m) => m.BaseWithdraw), {
  ssr: false,
  loading: () => null,
});

/**
 * Gasless withdraw via Base Account, shown when NEXT_PUBLIC_BASE_ACCOUNT is on.
 * Renders nothing otherwise, so the custodial WithdrawForm remains the default.
 */
export function BaseWalletActions() {
  if (!baseAccountEnabled()) return null;
  return (
    <BaseProviders>
      <BaseWithdraw />
    </BaseProviders>
  );
}
