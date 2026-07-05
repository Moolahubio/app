import { useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import { AlertCircle, KeyRound, ArrowLeft, Eye, EyeOff, MailCheck } from "lucide-react";
import { Button } from "@/components/ui";
import { useForgotPassword, useResetPassword } from "@workspace/api-client-react";
import { apiErrorMessage } from "@/lib/utils";
import { authInputClass } from "./AuthShell";

type Phase = "request" | "reset";

export function ForgotPasswordStep({
  initialEmail,
  onDone,
  onCancel,
}: {
  initialEmail?: string;
  onDone: (email: string) => void;
  onCancel: () => void;
}) {
  const { t } = useTranslation("auth");
  const forgot = useForgotPassword();
  const reset = useResetPassword();

  const [phase, setPhase] = useState<Phase>("request");
  const [email, setEmail] = useState(initialEmail ?? "");
  const [code, setCode] = useState("");
  const [newPassword, setNewPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [resent, setResent] = useState(false);

  const handleRequest = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setResent(false);
    try {
      await forgot.mutateAsync({ data: { email: email.trim() } });
      setPhase("reset");
    } catch (err) {
      setError(apiErrorMessage(err) ?? t("forgot.genericError"));
    }
  };

  const handleResend = async () => {
    setError(null);
    setResent(false);
    try {
      await forgot.mutateAsync({ data: { email: email.trim() } });
      setResent(true);
    } catch (err) {
      setError(apiErrorMessage(err) ?? t("resend.error"));
    }
  };

  const handleReset = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    try {
      await reset.mutateAsync({
        data: { email: email.trim(), code: code.trim(), newPassword },
      });
      onDone(email.trim());
    } catch (err) {
      setError(apiErrorMessage(err) ?? t("forgot.codeError"));
    }
  };

  if (phase === "request") {
    return (
      <form onSubmit={handleRequest} className="space-y-5">
        <div className="flex items-center gap-3">
          <span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-jade-50 text-jade-600 dark:bg-jade-500/15 dark:text-jade-300">
            <KeyRound className="h-5 w-5" />
          </span>
          <div>
            <h2 className="font-display text-lg font-bold text-foreground">{t("forgot.title")}</h2>
            <p className="text-sm text-muted-foreground">
              {t("forgot.subtitle")}
            </p>
          </div>
        </div>

        <label className="block">
          <span className="text-sm font-medium text-foreground">{t("fields.email")}</span>
          <input
            type="email"
            autoComplete="email"
            autoFocus
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder={t("fields.emailPlaceholder")}
            className={`mt-1.5 ${authInputClass}`}
          />
        </label>

        {error && (
          <p className="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
            <AlertCircle className="h-4 w-4 shrink-0" /> {error}
          </p>
        )}

        <Button type="submit" size="lg" className="w-full" disabled={forgot.isPending || !email.trim()}>
          {forgot.isPending ? t("forgot.submitting") : t("forgot.submit")}
        </Button>

        <button
          type="button"
          onClick={onCancel}
          className="flex items-center gap-1.5 text-sm font-medium text-muted-foreground transition-colors hover:text-foreground"
        >
          <ArrowLeft className="h-4 w-4 rtl:rotate-180" /> {t("backToSignIn")}
        </button>
      </form>
    );
  }

  return (
    <form onSubmit={handleReset} className="space-y-5">
      <div className="flex items-center gap-3">
        <span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-jade-50 text-jade-600 dark:bg-jade-500/15 dark:text-jade-300">
          <MailCheck className="h-5 w-5" />
        </span>
        <div>
          <h2 className="font-display text-lg font-bold text-foreground">{t("forgot.resetTitle")}</h2>
          <p className="text-sm text-muted-foreground">
            <Trans
              t={t}
              i18nKey="forgot.resetSentTo"
              values={{ email }}
              components={[<span className="font-medium text-foreground" />]}
            />
          </p>
        </div>
      </div>

      <label className="block">
        <span className="text-sm font-medium text-foreground">{t("fields.resetCode")}</span>
        <input
          inputMode="numeric"
          autoComplete="one-time-code"
          autoFocus
          placeholder={t("fields.codePlaceholder")}
          value={code}
          onChange={(e) => setCode(e.target.value)}
          className="mt-1.5 mh-input w-full rounded-xl px-3.5 py-3 text-center font-mono text-lg tracking-[0.3em] outline-none focus-ring"
        />
      </label>

      <label className="block">
        <span className="text-sm font-medium text-foreground">{t("fields.newPassword")}</span>
        <div className="relative mt-1.5">
          <input
            type={showPassword ? "text" : "password"}
            autoComplete="new-password"
            required
            minLength={8}
            value={newPassword}
            onChange={(e) => setNewPassword(e.target.value)}
            placeholder={t("fields.passwordMinPlaceholder")}
            className={`${authInputClass} pe-10`}
          />
          <button
            type="button"
            onClick={() => setShowPassword((s) => !s)}
            className="absolute inset-y-0 end-0 flex items-center px-3 text-muted-foreground hover:text-foreground focus-ring"
            aria-label={showPassword ? t("password.hide") : t("password.show")}
          >
            {showPassword ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
          </button>
        </div>
      </label>

      {error && (
        <p className="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
          <AlertCircle className="h-4 w-4 shrink-0" /> {error}
        </p>
      )}
      {resent && !error && (
        <p className="text-sm text-jade-600 dark:text-jade-400">{t("resend.sent")}</p>
      )}

      <Button
        type="submit"
        size="lg"
        className="w-full"
        disabled={reset.isPending || code.trim().length < 6 || newPassword.length < 8}
      >
        {reset.isPending ? t("forgot.resetSubmitting") : t("forgot.resetSubmit")}
      </Button>

      <div className="flex items-center justify-between text-sm">
        <button
          type="button"
          onClick={onCancel}
          className="flex items-center gap-1.5 font-medium text-muted-foreground transition-colors hover:text-foreground"
        >
          <ArrowLeft className="h-4 w-4 rtl:rotate-180" /> {t("common:actions.back")}
        </button>
        <button
          type="button"
          onClick={handleResend}
          disabled={forgot.isPending}
          className="font-medium text-jade-600 transition-colors hover:text-jade-700 disabled:opacity-60 dark:text-jade-400"
        >
          {forgot.isPending ? t("resend.sending") : t("resend.action")}
        </button>
      </div>
    </form>
  );
}
