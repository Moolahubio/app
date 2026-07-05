import { useState } from "react";
import { useTranslation } from "react-i18next";
import { ShieldCheck, AlertCircle, Copy, Check, KeyRound } from "lucide-react";
import { Card, Button, Badge } from "@/components/ui";
import {
  useGetTwoFactorStatus,
  useSetupTwoFactor,
  useEnableTwoFactor,
  useDisableTwoFactor,
  useRegenerateBackupCodes,
  getGetTwoFactorStatusQueryKey,
} from "@workspace/api-client-react";
import { useQueryClient } from "@tanstack/react-query";
import { apiErrorMessage } from "@/lib/utils";
import { useStepUpGate } from "@/components/app/StepUpDialog";

type SetupState = {
  secret: string;
  otpauthUrl: string;
  qrDataUrl: string;
} | null;

function BackupCodesPanel({ codes }: { codes: string[] }) {
  const { t } = useTranslation("account");
  const [copied, setCopied] = useState(false);
  const copyAll = async () => {
    try {
      await navigator.clipboard.writeText(codes.join("\n"));
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      /* ignore */
    }
  };
  return (
    <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4 dark:border-amber-400/25 dark:bg-amber-500/10">
      <div className="flex items-center justify-between gap-3">
        <p className="text-sm font-semibold text-amber-800 dark:text-amber-300">
          {t("twoFactor.backupCodes.title")}
        </p>
        <button
          type="button"
          onClick={copyAll}
          className="inline-flex items-center gap-1.5 rounded-lg px-2 py-1 text-xs font-medium text-amber-800 transition-colors hover:bg-amber-100 dark:text-amber-300 dark:hover:bg-amber-500/15 focus-ring"
        >
          {copied ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
          {copied ? t("common:forms.copied") : t("twoFactor.backupCodes.copyAll")}
        </button>
      </div>
      <p className="mt-1 text-xs text-amber-700 dark:text-amber-400/90">
        {t("twoFactor.backupCodes.description")}
      </p>
      <div className="mt-3 grid grid-cols-2 gap-2 font-mono text-sm text-amber-900 dark:text-amber-200">
        {codes.map((c) => (
          <span key={c} className="rounded-lg bg-white/60 px-2 py-1 dark:bg-black/20">
            {c}
          </span>
        ))}
      </div>
    </div>
  );
}

export function TwoFactorCard() {
  const { t } = useTranslation("account");
  const queryClient = useQueryClient();
  const { data: status, isLoading } = useGetTwoFactorStatus();
  const setupMutation = useSetupTwoFactor();
  const enableMutation = useEnableTwoFactor();
  const disableMutation = useDisableTwoFactor();
  const regenerateMutation = useRegenerateBackupCodes();
  const { requestProof, stepUpDialog } = useStepUpGate();

  const [setup, setSetup] = useState<SetupState>(null);
  const [code, setCode] = useState("");
  const [disableCode, setDisableCode] = useState("");
  const [regenCode, setRegenCode] = useState("");
  const [backupCodes, setBackupCodes] = useState<string[] | null>(null);
  const [disabling, setDisabling] = useState(false);
  const [regenerating, setRegenerating] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const enabled = status?.enabled ?? false;

  const invalidate = () =>
    queryClient.invalidateQueries({ queryKey: getGetTwoFactorStatusQueryKey() });

  const startSetup = async () => {
    setError(null);
    setBackupCodes(null);
    const proof = await requestProof();
    if (!proof) return;
    try {
      const res = await setupMutation.mutateAsync({ data: proof });
      setSetup(res);
      setCode("");
    } catch (err) {
      setError(apiErrorMessage(err) ?? t("twoFactor.errors.startSetup"));
    }
  };

  const confirmEnable = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    // A fresh step-up proof is required here too: for passwordless/2FA-less
    // accounts the emailed reauth code used at /setup is single-use, so it
    // can't be replayed for /enable. Ask again rather than reusing it.
    const proof = await requestProof();
    if (!proof) return;
    try {
      const res = await enableMutation.mutateAsync({
        data: { code: code.trim(), ...proof },
      });
      setBackupCodes(res.backupCodes);
      setSetup(null);
      setCode("");
      await invalidate();
    } catch (err) {
      setError(apiErrorMessage(err) ?? t("twoFactor.errors.codeFailed"));
    }
  };

  const confirmDisable = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    try {
      await disableMutation.mutateAsync({ data: { code: disableCode.trim() } });
      setDisabling(false);
      setDisableCode("");
      setBackupCodes(null);
      await invalidate();
    } catch (err) {
      setError(apiErrorMessage(err) ?? t("twoFactor.errors.codeFailed"));
    }
  };

  const regenerate = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    try {
      const res = await regenerateMutation.mutateAsync({ data: { code: regenCode.trim() } });
      setBackupCodes(res.backupCodes);
      setRegenerating(false);
      setRegenCode("");
      await invalidate();
    } catch (err) {
      setError(apiErrorMessage(err) ?? t("twoFactor.errors.codeFailed"));
    }
  };

  return (
    <Card className="p-5">
      <div className="flex items-start justify-between gap-3">
        <div className="flex items-center gap-3">
          <span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-muted text-foreground">
            <ShieldCheck className="h-5 w-5" />
          </span>
          <div>
            <div className="flex items-center gap-2">
              <p className="text-sm font-semibold text-foreground">{t("twoFactor.title")}</p>
              {enabled ? (
                <Badge tone="jade">{t("twoFactor.on")}</Badge>
              ) : (
                <Badge tone="neutral">{t("twoFactor.off")}</Badge>
              )}
            </div>
            <p className="text-xs text-muted-foreground">
              {t("twoFactor.description")}
            </p>
          </div>
        </div>
        {!isLoading && !enabled && !setup && (
          <Button size="sm" variant="secondary" onClick={startSetup} disabled={setupMutation.isPending}>
            {setupMutation.isPending ? t("twoFactor.starting") : t("twoFactor.setUp")}
          </Button>
        )}
      </div>

      {error && (
        <p className="mt-4 flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
          <AlertCircle className="h-4 w-4 shrink-0" /> {error}
        </p>
      )}

      {/* Setup flow */}
      {setup && (
        <form onSubmit={confirmEnable} className="mt-5 space-y-4">
          <p className="text-sm text-muted-foreground">
            {t("twoFactor.setup.instructions")}
          </p>
          <div className="flex flex-col items-center gap-3 rounded-2xl border border-border bg-muted/40 p-4">
            <img
              src={setup.qrDataUrl}
              alt={t("twoFactor.setup.qrAlt")}
              className="h-44 w-44 rounded-xl bg-white p-2"
            />
            <p className="text-center font-mono text-xs text-muted-foreground break-all">
              {setup.secret}
            </p>
          </div>
          <input
            inputMode="numeric"
            autoComplete="one-time-code"
            placeholder={t("twoFactor.setup.codePlaceholder")}
            value={code}
            onChange={(e) => setCode(e.target.value)}
            className="w-full rounded-xl border border-border bg-background px-3.5 py-2.5 text-center font-mono text-lg tracking-[0.3em] text-foreground outline-none focus:border-jade-500/60 focus-ring"
          />
          <div className="flex gap-3">
            <Button type="submit" disabled={enableMutation.isPending || code.trim().length < 6}>
              {enableMutation.isPending ? t("twoFactor.setup.verifying") : t("twoFactor.setup.enable")}
            </Button>
            <Button type="button" variant="ghost" onClick={() => setSetup(null)}>
              {t("common:actions.cancel")}
            </Button>
          </div>
        </form>
      )}

      {/* Backup codes just generated */}
      {backupCodes && (
        <div className="mt-5">
          <BackupCodesPanel codes={backupCodes} />
        </div>
      )}

      {/* Enabled management */}
      {enabled && !setup && (
        <div className="mt-5 space-y-4">
          {!backupCodes && (
            <p className="text-xs text-muted-foreground">
              {t("twoFactor.codesRemaining", { count: status?.backupCodesRemaining ?? 0 })}
            </p>
          )}
          <div className="flex flex-wrap gap-3">
            {!regenerating && (
              <Button
                size="sm"
                variant="secondary"
                onClick={() => {
                  setError(null);
                  setRegenerating(true);
                }}
              >
                <KeyRound className="h-4 w-4" />
                {t("twoFactor.regenerate")}
              </Button>
            )}
            {!disabling && (
              <Button size="sm" variant="ghost" onClick={() => setDisabling(true)}>
                {t("twoFactor.turnOff")}
              </Button>
            )}
          </div>

          {regenerating && (
            <form onSubmit={regenerate} className="space-y-3 rounded-2xl border border-border p-4">
              <p className="text-sm text-foreground">
                {t("twoFactor.regenerateForm.instructions")}
              </p>
              <input
                inputMode="numeric"
                autoComplete="one-time-code"
                placeholder={t("twoFactor.regenerateForm.codePlaceholder")}
                value={regenCode}
                onChange={(e) => setRegenCode(e.target.value)}
                className="w-full rounded-xl border border-border bg-background px-3.5 py-2.5 text-center font-mono tracking-[0.2em] text-foreground outline-none focus:border-jade-500/60 focus-ring"
              />
              <div className="flex gap-3">
                <Button
                  type="submit"
                  size="sm"
                  disabled={regenerateMutation.isPending || !regenCode.trim()}
                >
                  {regenerateMutation.isPending ? t("twoFactor.regenerateForm.generating") : t("twoFactor.regenerateForm.generate")}
                </Button>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  onClick={() => {
                    setRegenerating(false);
                    setRegenCode("");
                  }}
                >
                  {t("common:actions.cancel")}
                </Button>
              </div>
            </form>
          )}

          {disabling && (
            <form onSubmit={confirmDisable} className="space-y-3 rounded-2xl border border-border p-4">
              <p className="text-sm text-foreground">
                {t("twoFactor.disableForm.instructions")}
              </p>
              <input
                inputMode="numeric"
                autoComplete="one-time-code"
                placeholder={t("twoFactor.disableForm.codePlaceholder")}
                value={disableCode}
                onChange={(e) => setDisableCode(e.target.value)}
                className="w-full rounded-xl border border-border bg-background px-3.5 py-2.5 text-center font-mono tracking-[0.2em] text-foreground outline-none focus:border-jade-500/60 focus-ring"
              />
              <div className="flex gap-3">
                <Button
                  type="submit"
                  variant="primary"
                  size="sm"
                  disabled={disableMutation.isPending || !disableCode.trim()}
                >
                  {disableMutation.isPending ? t("twoFactor.disableForm.turningOff") : t("twoFactor.disableForm.confirmTurnOff")}
                </Button>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  onClick={() => {
                    setDisabling(false);
                    setDisableCode("");
                  }}
                >
                  {t("common:actions.cancel")}
                </Button>
              </div>
            </form>
          )}
        </div>
      )}

      {stepUpDialog}
    </Card>
  );
}
