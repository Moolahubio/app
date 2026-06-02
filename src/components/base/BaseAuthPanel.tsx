"use client";

import dynamic from "next/dynamic";
import { baseAccountEnabled } from "@/lib/base/wagmi";

// Browser-only, and only when Base Account is configured.
const BaseProviders = dynamic(() => import("./BaseProviders").then((m) => m.BaseProviders), {
  ssr: false,
  loading: () => null,
});
const SignInWithBase = dynamic(() => import("./SignInWithBase").then((m) => m.SignInWithBase), {
  ssr: false,
  loading: () => null,
});

/**
 * Renders the "Continue with Base" option above the email/password panel when
 * NEXT_PUBLIC_BASE_ACCOUNT === "true". Renders nothing otherwise, so the
 * default email flow is unchanged in dev.
 */
export function BaseAuthPanel() {
  if (!baseAccountEnabled()) return null;
  return (
    <div className="mb-5 space-y-4">
      <BaseProviders>
        <SignInWithBase />
      </BaseProviders>
      <div className="flex items-center gap-4">
        <span className="h-px flex-1 bg-ink-900/10" />
        <span className="font-mono text-[10px] uppercase tracking-[0.18em] text-ink-400">
          or use email
        </span>
        <span className="h-px flex-1 bg-ink-900/10" />
      </div>
    </div>
  );
}
