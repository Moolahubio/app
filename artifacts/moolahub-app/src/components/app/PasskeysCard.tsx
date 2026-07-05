import { useState } from "react";
import { useTranslation } from "react-i18next";
import { Fingerprint, Plus, Trash2, AlertCircle } from "lucide-react";
import { startRegistration, browserSupportsWebAuthn } from "@simplewebauthn/browser";
import type { PublicKeyCredentialCreationOptionsJSON } from "@simplewebauthn/browser";
import { Card, Button } from "@/components/ui";
import {
  useListPasskeys,
  useRegisterPasskeyOptions,
  useRegisterPasskeyVerify,
  useDeletePasskey,
  getListPasskeysQueryKey,
} from "@workspace/api-client-react";
import { apiErrorMessage, formatDate } from "@/lib/utils";
import { useQueryClient } from "@tanstack/react-query";
import { useStepUpGate } from "@/components/app/StepUpDialog";

export function PasskeysCard() {
  const { t } = useTranslation("account");
  const queryClient = useQueryClient();
  const { data, isLoading } = useListPasskeys();
  const optionsMutation = useRegisterPasskeyOptions();
  const verifyMutation = useRegisterPasskeyVerify();
  const deleteMutation = useDeletePasskey();
  const { requestProof, stepUpDialog } = useStepUpGate();

  const [error, setError] = useState<string | null>(null);
  const supported = browserSupportsWebAuthn();
  const passkeys = data?.passkeys ?? [];
  const adding = optionsMutation.isPending || verifyMutation.isPending;

  const invalidate = () =>
    queryClient.invalidateQueries({ queryKey: getListPasskeysQueryKey() });

  const handleAdd = async () => {
    setError(null);
    const proof = await requestProof();
    if (!proof) return;
    try {
      const { flowId, options } = await optionsMutation.mutateAsync({ data: proof });
      const response = await startRegistration({
        optionsJSON: options as unknown as PublicKeyCredentialCreationOptionsJSON,
      });
      const deviceName =
        typeof navigator !== "undefined" && navigator.platform
          ? navigator.platform
          : t("passkeys.defaultName");
      await verifyMutation.mutateAsync({
        data: { flowId, response: response as unknown as Record<string, unknown>, deviceName },
      });
      await invalidate();
    } catch (err) {
      if (err instanceof Error && err.name === "NotAllowedError") {
        setError(t("passkeys.errors.cancelled"));
      } else {
        setError(apiErrorMessage(err) ?? t("passkeys.errors.add"));
      }
    }
  };

  const handleRemove = async (id: string) => {
    setError(null);
    try {
      await deleteMutation.mutateAsync({ id });
      await invalidate();
    } catch (err) {
      setError(apiErrorMessage(err) ?? t("passkeys.errors.remove"));
    }
  };

  return (
    <Card className="p-5">
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-3">
          <span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-muted text-foreground">
            <Fingerprint className="h-5 w-5" />
          </span>
          <div>
            <p className="text-sm font-semibold text-foreground">{t("passkeys.title")}</p>
            <p className="text-xs text-muted-foreground">{t("passkeys.description")}</p>
          </div>
        </div>
        {supported && (
          <Button size="sm" variant="secondary" onClick={handleAdd} disabled={adding}>
            <Plus className="h-4 w-4" /> {adding ? t("passkeys.adding") : t("passkeys.add")}
          </Button>
        )}
      </div>

      {!supported && (
        <p className="mt-4 text-xs text-muted-foreground">
          {t("passkeys.unsupported")}
        </p>
      )}

      {error && (
        <p className="mt-4 flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
          <AlertCircle className="h-4 w-4 shrink-0" /> {error}
        </p>
      )}

      {isLoading ? (
        <p className="mt-4 text-xs text-muted-foreground">{t("passkeys.loading")}</p>
      ) : passkeys.length === 0 ? (
        <p className="mt-4 text-xs text-muted-foreground">{t("passkeys.empty")}</p>
      ) : (
        <ul className="mt-4 divide-y divide-border">
          {passkeys.map((p) => (
            <li key={p.id} className="flex items-center justify-between gap-3 py-3">
              <div className="min-w-0">
                <p className="truncate text-sm font-medium text-foreground">{p.deviceName ?? t("passkeys.defaultName")}</p>
                <p className="text-xs text-muted-foreground">
                  {t("passkeys.added", { date: formatDate(p.createdAt, { month: "short", day: "numeric", year: "numeric" }) })}
                  {p.lastUsedAt
                    ? ` · ${t("passkeys.lastUsed", { date: formatDate(p.lastUsedAt, { month: "short", day: "numeric" }) })}`
                    : ""}
                </p>
              </div>
              <button
                onClick={() => handleRemove(p.id)}
                disabled={deleteMutation.isPending}
                className="flex h-9 w-9 items-center justify-center rounded-xl text-muted-foreground transition-colors hover:bg-red-50 hover:text-red-600 dark:hover:bg-red-500/15 dark:hover:text-red-400 focus-ring"
                aria-label={t("passkeys.remove")}
              >
                <Trash2 className="h-4 w-4" />
              </button>
            </li>
          ))}
        </ul>
      )}

      {stepUpDialog}
    </Card>
  );
}
