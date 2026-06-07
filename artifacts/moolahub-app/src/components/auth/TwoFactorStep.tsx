import { useState } from "react";
import { AlertCircle, ShieldCheck, ArrowLeft } from "lucide-react";
import { useLocation } from "wouter";
import { Button } from "@/components/ui";
import { useTwoFactorLogin, getGetMeQueryKey } from "@workspace/api-client-react";
import { useQueryClient } from "@tanstack/react-query";
import { apiErrorMessage } from "@/lib/utils";

export function TwoFactorStep({
  challengeId,
  onCancel,
}: {
  challengeId: string;
  onCancel: () => void;
}) {
  const [, setLocation] = useLocation();
  const queryClient = useQueryClient();
  const twoFactorLogin = useTwoFactorLogin();
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    try {
      await twoFactorLogin.mutateAsync({
        data: { challengeId, code: code.trim() },
      });
      queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() });
      setLocation("/");
    } catch (err) {
      setError(apiErrorMessage(err) ?? "That code didn't work. Try again.");
    }
  };

  return (
    <form onSubmit={handleSubmit} className="space-y-5">
      <div className="flex items-center gap-3">
        <span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-jade-50 text-jade-600 dark:bg-jade-500/15 dark:text-jade-300">
          <ShieldCheck className="h-5 w-5" />
        </span>
        <div>
          <h2 className="font-display text-lg font-bold text-foreground">
            Two-factor authentication
          </h2>
          <p className="text-sm text-muted-foreground">
            Enter the 6-digit code from your authenticator app, or a backup code.
          </p>
        </div>
      </div>

      <input
        inputMode="numeric"
        autoComplete="one-time-code"
        autoFocus
        placeholder="123456"
        value={code}
        onChange={(e) => setCode(e.target.value)}
        className="w-full rounded-xl border border-border bg-background px-3.5 py-3 text-center font-mono text-lg tracking-[0.3em] text-foreground outline-none focus:border-jade-500/60 focus-ring"
      />

      {error && (
        <p className="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
          <AlertCircle className="h-4 w-4 shrink-0" /> {error}
        </p>
      )}

      <Button
        type="submit"
        size="lg"
        className="w-full"
        disabled={twoFactorLogin.isPending || code.trim().length < 6}
      >
        {twoFactorLogin.isPending ? "Verifying…" : "Verify & sign in"}
      </Button>

      <button
        type="button"
        onClick={onCancel}
        className="flex w-full items-center justify-center gap-1.5 text-sm font-medium text-muted-foreground transition-colors hover:text-foreground"
      >
        <ArrowLeft className="h-4 w-4" /> Back to sign in
      </button>
    </form>
  );
}
