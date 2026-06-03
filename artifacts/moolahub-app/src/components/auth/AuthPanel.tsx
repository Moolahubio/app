import { AuthForm } from "./AuthForm";
import { PrivyAuth } from "./PrivyAuth";

export function AuthPanel() {
  const appId = import.meta.env.VITE_PRIVY_APP_ID;

  if (!appId || appId.length < 10) return <AuthForm />;

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
