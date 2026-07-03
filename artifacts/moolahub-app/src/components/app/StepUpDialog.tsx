import { useCallback, useRef, useState } from "react";
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
  const { data: me } = useGetMe();
  const hasPassword = me?.hasPassword ?? false;
  const { data: twoFactor } = useGetTwoFactorStatus({
    query: { queryKey: getGetTwoFactorStatusQueryKey(), enabled: !hasPassword },
  });
  const requestCode = useRequestStepUpCode();

  const method: "password" | "totp" | "email" = hasPassword
    ? "password"
    : twoFactor?.enabled
      ? "totp"
      : "email";

  const [open, setOpen] = useState(false);
  const [value, setValue] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [codeSent, setCodeSent] = useState(false);
  const resolverRef = useRef<((proof: StepUpProof | null) => void) | null>(null);

  const requestProof = useCallback((): Promise<StepUpProof | null> => {
    setValue("");
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
      setError(apiErrorMessage(err) ?? "Could not send the code. Please try again.");
    }
  };

  const handleConfirm = () => {
    const trimmed = value.trim();
    if (!trimmed) {
      setError("Please enter a value to continue.");
      return;
    }
    if (method === "password") {
      finish({ currentPassword: value });
    } else if (method === "totp") {
      finish({ twoFactorCode: trimmed });
    } else {
      finish({ reauthCode: trimmed });
    }
  };

  const stepUpDialog = (
    <Dialog open={open} onOpenChange={(next) => !next && finish(null)}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Confirm it's you</DialogTitle>
          <DialogDescription>
            {method === "password" && "Enter your password to continue."}
            {method === "totp" && "Enter your two-factor authentication code to continue."}
            {method === "email" && "We'll email you a one-time code to confirm this change."}
          </DialogDescription>
        </DialogHeader>

        {method === "email" && !codeSent ? (
          <Button onClick={handleSendCode} disabled={requestCode.isPending}>
            {requestCode.isPending ? "Sending…" : "Send code"}
          </Button>
        ) : (
          <input
            type={method === "password" ? "password" : "text"}
            inputMode={method === "password" ? undefined : "numeric"}
            autoComplete={method === "password" ? "current-password" : "one-time-code"}
            autoFocus
            value={value}
            onChange={(e) => setValue(e.target.value)}
            placeholder={method === "password" ? "Current password" : "6-digit code"}
            className={inputClass}
          />
        )}

        {error && (
          <p className="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
            <AlertCircle className="h-4 w-4 shrink-0" /> {error}
          </p>
        )}

        <DialogFooter>
          <Button variant="ghost" onClick={() => finish(null)}>
            Cancel
          </Button>
          <Button onClick={handleConfirm} disabled={method === "email" && !codeSent}>
            Confirm
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );

  return { requestProof, stepUpDialog };
}
