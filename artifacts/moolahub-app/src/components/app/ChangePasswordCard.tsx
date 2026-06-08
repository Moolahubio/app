import { useState } from "react";
import { KeyRound, AlertCircle, Check, Eye, EyeOff } from "lucide-react";
import { Card, Button } from "@/components/ui";
import { useGetMe, useChangePassword, getGetMeQueryKey } from "@workspace/api-client-react";
import { useQueryClient } from "@tanstack/react-query";
import { apiErrorMessage } from "@/lib/utils";

const inputClass =
  "w-full rounded-xl border border-border bg-background px-3.5 py-2.5 text-sm text-foreground outline-none transition-colors placeholder:text-muted-foreground focus:border-jade-500/60 focus-ring";

export function ChangePasswordCard() {
  const { data: user } = useGetMe();
  const changePassword = useChangePassword();
  const queryClient = useQueryClient();

  const hasPassword = user?.hasPassword ?? false;

  const [open, setOpen] = useState(false);
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [confirm, setConfirm] = useState("");
  const [show, setShow] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  const reset = () => {
    setOpen(false);
    setCurrent("");
    setNext("");
    setConfirm("");
    setError(null);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setDone(false);
    if (next.length < 8) return setError("Password must be at least 8 characters.");
    if (next !== confirm) return setError("Passwords don't match.");
    try {
      await changePassword.mutateAsync({
        data: { currentPassword: hasPassword ? current : null, newPassword: next },
      });
      await queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() });
      reset();
      setDone(true);
    } catch (err) {
      setError(apiErrorMessage(err) ?? "Could not update your password.");
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
        {!open && (
          <Button size="sm" variant="secondary" onClick={() => { setOpen(true); setDone(false); }}>
            {hasPassword ? "Change" : "Set password"}
          </Button>
        )}
      </div>

      {done && !open && (
        <p className="mt-4 flex items-center gap-1.5 text-sm text-jade-600 dark:text-jade-400">
          <Check className="h-4 w-4 shrink-0" /> Password updated.
        </p>
      )}

      {open && (
        <form onSubmit={handleSubmit} className="mt-5 space-y-4">
          {hasPassword && (
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
          )}
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
            <Button type="button" variant="ghost" size="sm" onClick={reset}>
              Cancel
            </Button>
          </div>
        </form>
      )}
    </Card>
  );
}
