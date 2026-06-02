"use client";

import dynamic from "next/dynamic";
import { AuthForm } from "./AuthForm";

// Only loaded in the browser, and only when Privy is configured.
const PrivyAuth = dynamic(() => import("./PrivyAuth").then((m) => m.PrivyAuth), {
  ssr: false,
  loading: () => null,
});

/**
 * Chooses the auth experience: Privy (when NEXT_PUBLIC_PRIVY_APP_ID is set in
 * production) with email/password as a secondary option; otherwise just the
 * email/password form. The rest of the app only depends on the session cookie.
 */
export function AuthPanel() {
  const appId = process.env.NEXT_PUBLIC_PRIVY_APP_ID;

  if (!appId) return <AuthForm />;

  return (
    <div className="space-y-5">
      <PrivyAuth appId={appId} />
      <div className="flex items-center gap-4">
        <span className="h-px flex-1 bg-ink-900/10" />
        <span className="font-mono text-[10px] uppercase tracking-[0.18em] text-ink-400">
          or use email
        </span>
        <span className="h-px flex-1 bg-ink-900/10" />
      </div>
      <AuthForm />
    </div>
  );
}
