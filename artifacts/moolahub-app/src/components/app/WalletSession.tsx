import { useEffect } from "react";
import { usePrivy, useLogin } from "@privy-io/react-auth";
import { Wallet } from "lucide-react";
import { Button } from "@/components/ui";
import { useGetMe, useGetWallet, getGetMeQueryKey } from "@workspace/api-client-react";
import { isWeb3Enabled } from "@/components/app/Web3Provider";

/**
 * Keeps the wallet (Privy) session tied to the app session.
 *
 * The two are otherwise independent: Privy persists its own login in
 * localStorage and would survive an app sign-out, while the app never
 * proactively ends it. Here we end the Privy session once the app session is
 * gone, so signing back in is a clean "log into the app + wallet again" — which
 * matches the intended model: connect once, transact freely until you log out.
 *
 * Rendered at the app root (outside AppLayout) so it stays mounted across the
 * logged-in ⇄ logged-out transition and can observe the sign-out.
 */
export function WalletSessionSync() {
  if (!isWeb3Enabled) return null;
  return <WalletSessionSyncInner />;
}

function WalletSessionSyncInner() {
  const { data: user, isSuccess } = useGetMe({
    query: { queryKey: getGetMeQueryKey(), retry: false, staleTime: Infinity },
  });
  const { ready, authenticated, logout } = usePrivy();

  // Only a POSITIVE confirmation that the app session is gone: the /auth/me
  // query resolved successfully to null, which is what an explicit app sign-out
  // does (it sets the cached me to null). We deliberately ignore the query's
  // error state — a transient network failure or a 5xx must NOT tear down a
  // still-valid wallet session for a returning, cookie-authed user.
  const appSessionEnded = isSuccess && !user;

  useEffect(() => {
    if (appSessionEnded && ready && authenticated) {
      void logout();
    }
  }, [appSessionEnded, ready, authenticated, logout]);

  return null;
}

/**
 * A one-time, per-session prompt to connect the wallet, shown at the top of the
 * app shell for users who already own a non-custodial (Privy) wallet but whose
 * wallet session isn't live yet. Connecting here — once, up front — means the
 * withdrawal / contribution / goal flows never have to interrupt with their own
 * "connect wallet" step mid-transaction. It disappears the moment the wallet
 * session is active and stays gone until the next app login.
 */
export function WalletSessionBanner() {
  if (!isWeb3Enabled) return null;
  return <WalletSessionBannerInner />;
}

function WalletSessionBannerInner() {
  const { data: wallet } = useGetWallet();
  const { data: me } = useGetMe();
  const { ready, authenticated } = usePrivy();
  const { login } = useLogin();

  const isPrivyWallet = wallet?.custody === "privy";
  // Only prompt when there is genuinely something to do: the user owns a
  // self-custody wallet but hasn't connected it in this session. Users without a
  // wallet yet go through WalletSetupCard on the wallet page instead.
  if (!ready || !isPrivyWallet || authenticated) return null;

  const handleConnect = () => {
    const email = me?.email?.trim();
    // Prefill with the account email so they reconnect the SAME embedded wallet
    // linked at setup — a different Privy identity would be a different signing
    // address, which fails on-chain withdrawal verification.
    login(email ? { prefill: { type: "email", value: email } } : undefined);
  };

  return (
    <div className="mb-6 flex flex-col gap-3 rounded-2xl border border-jade-500/30 bg-jade-50 p-4 dark:bg-jade-500/10 sm:flex-row sm:items-center sm:justify-between">
      <div className="flex items-start gap-3">
        <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-jade-500/15 text-jade-600 dark:text-jade-300">
          <Wallet className="h-5 w-5" />
        </span>
        <div>
          <p className="text-sm font-semibold text-foreground">Connect your wallet for this session</p>
          <p className="text-sm text-muted-foreground">
            Connect once now and you can deposit, save, and withdraw without connecting again until you sign out.
          </p>
        </div>
      </div>
      <Button variant="secondary" className="shrink-0" onClick={handleConnect}>
        Connect wallet
      </Button>
    </div>
  );
}
