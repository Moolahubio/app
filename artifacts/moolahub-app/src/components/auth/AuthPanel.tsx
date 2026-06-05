import { AlertCircle } from "lucide-react";
import { PasskeySignIn } from "./AuthForm";
import { PrivyAuth } from "./PrivyAuth";

export function AuthPanel() {
  const appId = import.meta.env.VITE_PRIVY_APP_ID;
  const privyReady = Boolean(appId && appId.length >= 10);

  return (
    <div className="space-y-5">
      <div>
        <h2 className="font-display text-2xl font-bold tracking-tight text-ink-900">
          Welcome to MoolaHub
        </h2>
        <p className="mt-2 text-sm leading-relaxed text-ink-500">
          Save smarter, together. Open a wallet in minutes, chase your goals, and grow your money with circles you trust.
        </p>
      </div>

      {privyReady ? (
        <PrivyAuth appId={appId} />
      ) : (
        <p className="flex items-center gap-1.5 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-800" role="alert">
          <AlertCircle className="h-4 w-4 shrink-0" /> Sign-in is not configured yet.
        </p>
      )}

      <div className="flex items-center gap-4">
        <span className="h-px flex-1 bg-ink-900/10" />
        <span className="font-mono text-[10px] uppercase tracking-[0.18em] text-ink-400">
          or
        </span>
        <span className="h-px flex-1 bg-ink-900/10" />
      </div>

      <PasskeySignIn />
    </div>
  );
}
