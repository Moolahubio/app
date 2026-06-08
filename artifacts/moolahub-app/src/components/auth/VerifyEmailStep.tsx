import { useState } from "react";
import { AlertCircle, MailCheck, ArrowLeft } from "lucide-react";
import { useLocation } from "wouter";
import { useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui";
import {
  useVerifyEmail,
  useResendVerificationCode,
  getGetMeQueryKey,
} from "@workspace/api-client-react";
import { apiErrorMessage } from "@/lib/utils";

export function VerifyEmailStep({
  email,
  rememberMe,
  onTwoFactorRequired,
  onCancel,
}: {
  email: string;
  rememberMe: boolean;
  onTwoFactorRequired: (challengeId: string) => void;
  onCancel: () => void;
}) {
  const [, setLocation] = useLocation();
  const queryClient = useQueryClient();
  const verifyEmail = useVerifyEmail();
  const resendCode = useResendVerificationCode();

  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [resent, setResent] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    try {
      const result = await verifyEmail.mutateAsync({
        data: { email, code: code.trim(), rememberMe },
      });
      if (result.twoFactorRequired) {
        if (result.challengeId) onTwoFactorRequired(result.challengeId);
        else setError("We couldn't start verification. Please try again.");
        return;
      }
      queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() });
      setLocation("/");
    } catch (err) {
      setError(apiErrorMessage(err) ?? "That code is invalid or has expired.");
    }
  };

  const handleResend = async () => {
    setError(null);
    setResent(false);
    try {
      await resendCode.mutateAsync({ data: { email } });
      setResent(true);
    } catch (err) {
      setError(apiErrorMessage(err) ?? "Could not resend the code.");
    }
  };

  return (
    <form onSubmit={handleSubmit} className="space-y-5">
      <div className="flex items-center gap-3">
        <span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-jade-50 text-jade-600 dark:bg-jade-500/15 dark:text-jade-300">
          <MailCheck className="h-5 w-5" />
        </span>
        <div>
          <h2 className="font-display text-lg font-bold text-foreground">Verify your email</h2>
          <p className="text-sm text-muted-foreground">
            We sent a 6-digit code to <span className="font-medium text-foreground">{email}</span>.
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
      {resent && !error && (
        <p className="text-sm text-jade-600 dark:text-jade-400">A new code is on its way.</p>
      )}

      <Button
        type="submit"
        size="lg"
        className="w-full"
        disabled={verifyEmail.isPending || code.trim().length < 6}
      >
        {verifyEmail.isPending ? "Verifying…" : "Verify & continue"}
      </Button>

      <div className="flex items-center justify-between text-sm">
        <button
          type="button"
          onClick={onCancel}
          className="flex items-center gap-1.5 font-medium text-muted-foreground transition-colors hover:text-foreground"
        >
          <ArrowLeft className="h-4 w-4" /> Back
        </button>
        <button
          type="button"
          onClick={handleResend}
          disabled={resendCode.isPending}
          className="font-medium text-jade-600 transition-colors hover:text-jade-700 disabled:opacity-60 dark:text-jade-400"
        >
          {resendCode.isPending ? "Sending…" : "Resend code"}
        </button>
      </div>
    </form>
  );
}
