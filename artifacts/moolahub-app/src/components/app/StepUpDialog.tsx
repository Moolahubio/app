import { useCallback, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { AlertCircle } from "lucide-react";
import { Button } from "@/components/ui";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogFooter,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import {
  useGetMe,
  useGetTwoFactorStatus,
  useRequestStepUpCode,
  getGetTwoFactorStatusQueryKey,
} from "@workspace/api-client-react";
import { apiErrorMessage } from "@/lib/utils";

export type StepUpProof = {
  currentPassword?: string;
  twoFactorCode?: string;
  reauthCode?: string;
};

const inputClass =
  "w-full rounded-xl border border-border bg-background px-3.5 py-2.5 text-sm text-foreground outline-none transition-colors placeholder:text-muted-foreground focus:border-jade-500/60 focus-ring";

/**
 * Reusable "confirm it's you" gate for sensitive account changes (adding a
 * passkey, linking a new Privy wallet, setting a first password). Resolves
 * with a StepUpProof to attach to the follow-up request, or null if the user
 * cancels.
 */
export function useStepUpGate() {
  const { t } = useTranslation("account");
  const { data: me } = useGetMe();
  const hasPassword = me?.hasPassword ?? false;
  const { data: twoFactor } = useGetTwoFactorStatus({
    query: { queryKey: getGetTwoFactorStatusQueryKey() },
  });
  const requestCode = useRequestStepUpCode();

  const needsPassword = hasPassword;
  const needsTotp = twoFactor?.enabled ?? false;
  // Only when the account has NEITHER a password nor 2FA do we fall back to
  // an emailed one-time code. Whenever a password AND 2FA are both
  // configured, the backend requires BOTH — asking for only one would let a
  // stolen session + a single leaked factor bypass the second one.
  const needsEmail = !needsPassword && !needsTotp;

  const [open, setOpen] = useState(false);
  const [password, setPassword] = useState("");
  const [totpCode, setTotpCode] = useState("");
  const [emailCode, setEmailCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [codeSent, setCodeSent] = useState(false);
  const resolverRef = useRef<((proof: StepUpProof | null) => void) | null>(null);

  const requestProof = useCallback((): Promise<StepUpProof | null> => {
    setPassword("");
    setTotpCode("");
    setEmailCode("");
    setError(null);
    setCodeSent(false);
    setOpen(true);
    return new Promise((resolve) => {
      resolverRef.current = resolve;
    });
  }, []);

  const finish = (proof: StepUpProof | null) => {
    setOpen(false);
    resolverRef.current?.(proof);
    resolverRef.current = null;
  };

  const handleSendCode = async () => {
    setError(null);
    try {
      await requestCode.mutateAsync();
      setCodeSent(true);
    } catch (err) {
      setError(apiErrorMessage(err) ?? t("stepUp.errors.sendCode"));
    }
  };

  const handleConfirm = () => {
    if (needsEmail) {
      const trimmed = emailCode.trim();
      if (!trimmed) {
        setError(t("stepUp.errors.enterEmailCode"));
        return;
      }
      finish({ reauthCode: trimmed });
      return;
    }

    if (needsPassword && !password) {
      setError(t("stepUp.errors.enterPassword"));
      return;
    }
    if (needsTotp && !totpCode.trim()) {
      setError(t("stepUp.errors.enterTotp"));
      return;
    }

    const proof: StepUpProof = {};
    if (needsPassword) proof.currentPassword = password;
    if (needsTotp) proof.twoFactorCode = totpCode.trim();
    finish(proof);
  };

  const stepUpDialog = (
    <Dialog open={open} onOpenChange={(next) => !next && finish(null)}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t("stepUp.title")}</DialogTitle>
          <DialogDescription>
            {needsPassword && needsTotp && t("stepUp.descBoth")}
            {needsPassword && !needsTotp && t("stepUp.descPassword")}
            {!needsPassword && needsTotp && t("stepUp.descTotp")}
            {needsEmail && t("stepUp.descEmail")}
          </DialogDescription>
        </DialogHeader>

        {needsEmail ? (
          !codeSent ? (
            <Button onClick={handleSendCode} disabled={requestCode.isPending}>
              {requestCode.isPending ? t("stepUp.sending") : t("stepUp.sendCode")}
            </Button>
          ) : (
            <input
              type="text"
              inputMode="numeric"
              autoComplete="one-time-code"
              autoFocus
              value={emailCode}
              onChange={(e) => setEmailCode(e.target.value)}
              placeholder={t("stepUp.codePlaceholder")}
              className={inputClass}
            />
          )
        ) : (
          <div className="flex flex-col gap-3">
            {needsPassword && (
              <input
                type="password"
                autoComplete="current-password"
                autoFocus
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder={t("stepUp.passwordPlaceholder")}
                className={inputClass}
              />
            )}
            {needsTotp && (
              <input
                type="text"
                inputMode="numeric"
                autoComplete="one-time-code"
                autoFocus={!needsPassword}
                value={totpCode}
                onChange={(e) => setTotpCode(e.target.value)}
                placeholder={t("stepUp.codePlaceholder")}
                className={inputClass}
              />
            )}
          </div>
        )}

        {error && (
          <p className="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
            <AlertCircle className="h-4 w-4 shrink-0" /> {error}
          </p>
        )}

        <DialogFooter>
          <Button variant="ghost" onClick={() => finish(null)}>
            {t("common:actions.cancel")}
          </Button>
          <Button onClick={handleConfirm} disabled={needsEmail && !codeSent}>
            {t("common:actions.confirm")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );

  return { requestProof, stepUpDialog };
}
