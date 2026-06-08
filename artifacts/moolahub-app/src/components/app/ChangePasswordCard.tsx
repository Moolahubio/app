import { useState } from "react";
import { KeyRound, AlertCircle, Check, Eye, EyeOff, MailCheck } from "lucide-react";
import { Card, Button } from "@/components/ui";
import {
  useGetMe,
  useChangePassword,
  useForgotPassword,
  useResetPassword,
  getGetMeQueryKey,
} from "@workspace/api-client-react";
import { useQueryClient } from "@tanstack/react-query";
import { apiErrorMessage } from "@/lib/utils";

const inputClass =
  "w-full rounded-xl border border-border bg-background px-3.5 py-2.5 text-sm text-foreground outline-none transition-colors placeholder:text-muted-foreground focus:border-jade-500/60 focus-ring";

export function ChangePasswordCard() {
  const { data: user } = useGetMe();
  const changePassword = useChangePassword();
  const forgotPassword = useForgotPassword();
  const resetPassword = useResetPassword();
  const queryClient = useQueryClient();

  const hasPassword = user?.hasPassword ?? false;
  const emailVerified = user?.emailVerified ?? false;

  const [open, setOpen] = useState(false);
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [confirm, setConfirm] = useState("");
  const [show, setShow] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  // For first-time password set via email verification flow
  const [emailPhase, setEmailPhase] = useState<"request" | "code">("request");
  const [code, setCode] = useState("");

  const resetForm = () => {
    setOpen(false);
    setCurrent("");
    setNext("");
    setConfirm("");
    setCode("");
    setError(null);
    setEmailPhase("request");
  };

  // ── Change existing password (has a password already) ────────────────────
  const handleChange = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setDone(false);
    if (next.length < 8) return setError("Password must be at least 8 characters.");
    if (next !== confirm) return setError("Passwords don't match.");
    try {
      await changePassword.mutateAsync({
        data: { currentPassword: current, newPassword: next },
      });
      await queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() });
      resetForm();
      setDone(true);
    } catch (err) {
      setError(apiErrorMessage(err) ?? "Could not update your password.");
    }
  };

  // ── Set first password via email code ────────────────────────────────────
  const handleSendCode = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    if (!user?.email) return;
    try {
      await forgotPassword.mutateAsync({ data: { email: user.email } });
      setEmailPhase("code");
    } catch (err) {
      setError(apiErrorMessage(err) ?? "Could not send the code. Please try again.");
    }
  };

  const handleSetPassword = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    if (next.length < 8) return setError("Password must be at least 8 characters.");
    if (next !== confirm) return setError("Passwords don't match.");
    if (!user?.email) return;
    try {
      await resetPassword.mutateAsync({
        data: { email: user.email, code: code.trim(), newPassword: next },
      });
      // reset-password revokes all sessions; clear auth state and let the
      // app redirect to login.
      queryClient.setQueryData(getGetMeQueryKey(), null);
      queryClient.removeQueries({ predicate: (q) => q.queryKey[0] !== getGetMeQueryKey()[0] });
    } catch (err) {
      setError(apiErrorMessage(err) ?? "That code is invalid or has expired.");
    }
  };

  return (
    <Card className="p-5">
      <div className="flex items-start justify-between gap-3">
        <div className="flex items-center gap-3">
          <span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-muted text-foreground">
            <KeyRound className="h-5 w-5" />
          </span>
          <div>
            <p className="text-sm font-semibold text-foreground">Password</p>
            <p className="text-xs text-muted-foreground">
              {hasPassword
                ? "Change the password you use to sign in"
                : "Set a password to sign in with your email"}
            </p>
          </div>
        </div>
        {!open && hasPassword && (
          <Button size="sm" variant="secondary" onClick={() => { setOpen(true); setDone(false); }}>
            Change
          </Button>
        )}
        {!open && !hasPassword && emailVerified && (
          <Button size="sm" variant="secondary" onClick={() => { setOpen(true); setDone(false); }}>
            Set password
          </Button>
        )}
      </div>

      {done && !open && (
        <p className="mt-4 flex items-center gap-1.5 text-sm text-jade-600 dark:text-jade-400">
          <Check className="h-4 w-4 shrink-0" /> Password updated.
        </p>
      )}

      {!hasPassword && !emailVerified && (
        <p className="mt-4 text-xs text-muted-foreground">
          A verified email is required to set a password.
        </p>
      )}

      {/* ── Change existing password ── */}
      {open && hasPassword && (
        <form onSubmit={handleChange} className="mt-5 space-y-4">
          <label className="block">
            <span className="text-sm font-medium text-foreground">Current password</span>
            <input
              type={show ? "text" : "password"}
              autoComplete="current-password"
              value={current}
              onChange={(e) => setCurrent(e.target.value)}
              className={`mt-1.5 ${inputClass}`}
            />
          </label>
          <label className="block">
            <span className="text-sm font-medium text-foreground">New password</span>
            <div className="relative mt-1.5">
              <input
                type={show ? "text" : "password"}
                autoComplete="new-password"
                value={next}
                onChange={(e) => setNext(e.target.value)}
                placeholder="At least 8 characters"
                className={`${inputClass} pr-10`}
              />
              <button
                type="button"
                onClick={() => setShow((s) => !s)}
                className="absolute inset-y-0 right-0 flex items-center px-3 text-muted-foreground hover:text-foreground focus-ring"
                aria-label={show ? "Hide password" : "Show password"}
              >
                {show ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
              </button>
            </div>
          </label>
          <label className="block">
            <span className="text-sm font-medium text-foreground">Confirm new password</span>
            <input
              type={show ? "text" : "password"}
              autoComplete="new-password"
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
              className={`mt-1.5 ${inputClass}`}
            />
          </label>

          {error && (
            <p className="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
              <AlertCircle className="h-4 w-4 shrink-0" /> {error}
            </p>
          )}

          <div className="flex gap-3">
            <Button type="submit" size="sm" disabled={changePassword.isPending}>
              {changePassword.isPending ? "Saving…" : "Save password"}
            </Button>
            <Button type="button" variant="ghost" size="sm" onClick={resetForm}>
              Cancel
            </Button>
          </div>
        </form>
      )}

      {/* ── Set first password via email code ── */}
      {open && !hasPassword && emailPhase === "request" && (
        <form onSubmit={handleSendCode} className="mt-5 space-y-4">
          <p className="text-sm text-muted-foreground">
            We'll send a verification code to{" "}
            <span className="font-medium text-foreground">{user?.email}</span> to confirm
            it's you before setting a password.
          </p>

          {error && (
            <p className="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
              <AlertCircle className="h-4 w-4 shrink-0" /> {error}
            </p>
          )}

          <div className="flex gap-3">
            <Button type="submit" size="sm" disabled={forgotPassword.isPending}>
              {forgotPassword.isPending ? "Sending…" : "Send code"}
            </Button>
            <Button type="button" variant="ghost" size="sm" onClick={resetForm}>
              Cancel
            </Button>
          </div>
        </form>
      )}

      {open && !hasPassword && emailPhase === "code" && (
        <form onSubmit={handleSetPassword} className="mt-5 space-y-4">
          <div className="flex items-center gap-2 rounded-xl border border-border bg-muted/40 px-3.5 py-2.5">
            <MailCheck className="h-4 w-4 shrink-0 text-jade-600 dark:text-jade-400" />
            <p className="text-sm text-muted-foreground">
              Check your email for a 6-digit code.
            </p>
          </div>

          <label className="block">
            <span className="text-sm font-medium text-foreground">Verification code</span>
            <input
              inputMode="numeric"
              autoComplete="one-time-code"
              autoFocus
              placeholder="123456"
              value={code}
              onChange={(e) => setCode(e.target.value)}
              className="mt-1.5 w-full rounded-xl border border-border bg-background px-3.5 py-2.5 text-center font-mono text-lg tracking-[0.3em] text-foreground outline-none focus:border-jade-500/60 focus-ring"
            />
          </label>

          <label className="block">
            <span className="text-sm font-medium text-foreground">New password</span>
            <div className="relative mt-1.5">
              <input
                type={show ? "text" : "password"}
                autoComplete="new-password"
                value={next}
                onChange={(e) => setNext(e.target.value)}
                placeholder="At least 8 characters"
                className={`${inputClass} pr-10`}
              />
              <button
                type="button"
                onClick={() => setShow((s) => !s)}
                className="absolute inset-y-0 right-0 flex items-center px-3 text-muted-foreground hover:text-foreground focus-ring"
                aria-label={show ? "Hide password" : "Show password"}
              >
                {show ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
              </button>
            </div>
          </label>

          <label className="block">
            <span className="text-sm font-medium text-foreground">Confirm new password</span>
            <input
              type={show ? "text" : "password"}
              autoComplete="new-password"
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
              className={`mt-1.5 ${inputClass}`}
            />
          </label>

          {error && (
            <p className="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
              <AlertCircle className="h-4 w-4 shrink-0" /> {error}
            </p>
          )}

          <div className="flex gap-3">
            <Button
              type="submit"
              size="sm"
              disabled={resetPassword.isPending || code.trim().length < 6 || next.length < 8}
            >
              {resetPassword.isPending ? "Saving…" : "Set password"}
            </Button>
            <Button type="button" variant="ghost" size="sm" onClick={resetForm}>
              Cancel
            </Button>
          </div>
        </form>
      )}
    </Card>
  );
}
