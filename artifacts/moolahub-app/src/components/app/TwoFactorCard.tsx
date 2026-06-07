import { useState } from "react";
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

type SetupState = {
  secret: string;
  otpauthUrl: string;
  qrDataUrl: string;
} | null;

function BackupCodesPanel({ codes }: { codes: string[] }) {
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
          Save your backup codes
        </p>
        <button
          type="button"
          onClick={copyAll}
          className="inline-flex items-center gap-1.5 rounded-lg px-2 py-1 text-xs font-medium text-amber-800 transition-colors hover:bg-amber-100 dark:text-amber-300 dark:hover:bg-amber-500/15 focus-ring"
        >
          {copied ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
          {copied ? "Copied" : "Copy all"}
        </button>
      </div>
      <p className="mt-1 text-xs text-amber-700 dark:text-amber-400/90">
        Each code works once. Store them somewhere safe. They let you sign in if you
        lose your authenticator.
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
  const queryClient = useQueryClient();
  const { data: status, isLoading } = useGetTwoFactorStatus();
  const setupMutation = useSetupTwoFactor();
  const enableMutation = useEnableTwoFactor();
  const disableMutation = useDisableTwoFactor();
  const regenerateMutation = useRegenerateBackupCodes();

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
    try {
      const res = await setupMutation.mutateAsync();
      setSetup(res);
      setCode("");
    } catch (err) {
      setError(apiErrorMessage(err) ?? "Could not start setup.");
    }
  };

  const confirmEnable = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    try {
      const res = await enableMutation.mutateAsync({ data: { code: code.trim() } });
      setBackupCodes(res.backupCodes);
      setSetup(null);
      setCode("");
      await invalidate();
    } catch (err) {
      setError(apiErrorMessage(err) ?? "That code didn't work. Try again.");
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
      setError(apiErrorMessage(err) ?? "That code didn't work. Try again.");
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
      setError(apiErrorMessage(err) ?? "That code didn't work. Try again.");
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
              <p className="text-sm font-semibold text-foreground">Authenticator app</p>
              {enabled ? (
                <Badge tone="jade">On</Badge>
              ) : (
                <Badge tone="neutral">Off</Badge>
              )}
            </div>
            <p className="text-xs text-muted-foreground">
              Require a 6-digit code at sign-in for extra security
            </p>
          </div>
        </div>
        {!isLoading && !enabled && !setup && (
          <Button size="sm" variant="secondary" onClick={startSetup} disabled={setupMutation.isPending}>
            {setupMutation.isPending ? "Starting…" : "Set up"}
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
            Scan this QR code with Google Authenticator, 1Password, or any TOTP app,
            then enter the 6-digit code it shows.
          </p>
          <div className="flex flex-col items-center gap-3 rounded-2xl border border-border bg-muted/40 p-4">
            <img
              src={setup.qrDataUrl}
              alt="2FA QR code"
              className="h-44 w-44 rounded-xl bg-white p-2"
            />
            <p className="text-center font-mono text-xs text-muted-foreground break-all">
              {setup.secret}
            </p>
          </div>
          <input
            inputMode="numeric"
            autoComplete="one-time-code"
            placeholder="123456"
            value={code}
            onChange={(e) => setCode(e.target.value)}
            className="w-full rounded-xl border border-border bg-background px-3.5 py-2.5 text-center font-mono text-lg tracking-[0.3em] text-foreground outline-none focus:border-jade-500/60 focus-ring"
          />
          <div className="flex gap-3">
            <Button type="submit" disabled={enableMutation.isPending || code.trim().length < 6}>
              {enableMutation.isPending ? "Verifying…" : "Enable 2FA"}
            </Button>
            <Button type="button" variant="ghost" onClick={() => setSetup(null)}>
              Cancel
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
              {status?.backupCodesRemaining ?? 0} backup code
              {(status?.backupCodesRemaining ?? 0) === 1 ? "" : "s"} remaining.
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
                Regenerate backup codes
              </Button>
            )}
            {!disabling && (
              <Button size="sm" variant="ghost" onClick={() => setDisabling(true)}>
                Turn off
              </Button>
            )}
          </div>

          {regenerating && (
            <form onSubmit={regenerate} className="space-y-3 rounded-2xl border border-border p-4">
              <p className="text-sm text-foreground">
                Enter a current code or a backup code to generate a fresh set. Your old
                backup codes will stop working.
              </p>
              <input
                inputMode="numeric"
                autoComplete="one-time-code"
                placeholder="Code"
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
                  {regenerateMutation.isPending ? "Generating…" : "Generate new codes"}
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
                  Cancel
                </Button>
              </div>
            </form>
          )}

          {disabling && (
            <form onSubmit={confirmDisable} className="space-y-3 rounded-2xl border border-border p-4">
              <p className="text-sm text-foreground">
                Enter a current code or a backup code to turn off 2FA.
              </p>
              <input
                inputMode="numeric"
                autoComplete="one-time-code"
                placeholder="Code"
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
                  {disableMutation.isPending ? "Turning off…" : "Confirm turn off"}
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
                  Cancel
                </Button>
              </div>
            </form>
          )}
        </div>
      )}
    </Card>
  );
}
