import { useState } from "react";
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
import { apiErrorMessage } from "@/lib/utils";
import { useQueryClient } from "@tanstack/react-query";

export function PasskeysCard() {
  const queryClient = useQueryClient();
  const { data, isLoading } = useListPasskeys();
  const optionsMutation = useRegisterPasskeyOptions();
  const verifyMutation = useRegisterPasskeyVerify();
  const deleteMutation = useDeletePasskey();

  const [error, setError] = useState<string | null>(null);
  const supported = browserSupportsWebAuthn();
  const passkeys = data?.passkeys ?? [];
  const adding = optionsMutation.isPending || verifyMutation.isPending;

  const invalidate = () =>
    queryClient.invalidateQueries({ queryKey: getListPasskeysQueryKey() });

  const handleAdd = async () => {
    setError(null);
    try {
      const { flowId, options } = await optionsMutation.mutateAsync();
      const response = await startRegistration({
        optionsJSON: options as unknown as PublicKeyCredentialCreationOptionsJSON,
      });
      const deviceName =
        typeof navigator !== "undefined" && navigator.platform
          ? navigator.platform
          : "Passkey";
      await verifyMutation.mutateAsync({
        data: { flowId, response: response as unknown as Record<string, unknown>, deviceName },
      });
      await invalidate();
    } catch (err) {
      if (err instanceof Error && err.name === "NotAllowedError") {
        setError("Passkey setup was cancelled.");
      } else {
        setError(apiErrorMessage(err) ?? "Could not add passkey.");
      }
    }
  };

  const handleRemove = async (id: string) => {
    setError(null);
    try {
      await deleteMutation.mutateAsync({ id });
      await invalidate();
    } catch (err) {
      setError(apiErrorMessage(err) ?? "Could not remove passkey.");
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
            <p className="text-sm font-semibold text-foreground">Passkeys</p>
            <p className="text-xs text-muted-foreground">Sign in with Face ID, Touch ID, or a security key</p>
          </div>
        </div>
        {supported && (
          <Button size="sm" variant="secondary" onClick={handleAdd} disabled={adding}>
            <Plus className="h-4 w-4" /> {adding ? "Adding…" : "Add passkey"}
          </Button>
        )}
      </div>

      {!supported && (
        <p className="mt-4 text-xs text-muted-foreground">
          This browser does not support passkeys.
        </p>
      )}

      {error && (
        <p className="mt-4 flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
          <AlertCircle className="h-4 w-4 shrink-0" /> {error}
        </p>
      )}

      {isLoading ? (
        <p className="mt-4 text-xs text-muted-foreground">Loading passkeys…</p>
      ) : passkeys.length === 0 ? (
        <p className="mt-4 text-xs text-muted-foreground">No passkeys yet. Add one for faster, safer sign-in.</p>
      ) : (
        <ul className="mt-4 divide-y divide-border">
          {passkeys.map((p) => (
            <li key={p.id} className="flex items-center justify-between gap-3 py-3">
              <div className="min-w-0">
                <p className="truncate text-sm font-medium text-foreground">{p.deviceName ?? "Passkey"}</p>
                <p className="text-xs text-muted-foreground">
                  Added {new Date(p.createdAt).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" })}
                  {p.lastUsedAt
                    ? ` · Last used ${new Date(p.lastUsedAt).toLocaleDateString("en-US", { month: "short", day: "numeric" })}`
                    : ""}
                </p>
              </div>
              <button
                onClick={() => handleRemove(p.id)}
                disabled={deleteMutation.isPending}
                className="flex h-9 w-9 items-center justify-center rounded-xl text-muted-foreground transition-colors hover:bg-red-50 hover:text-red-600 dark:hover:bg-red-500/15 dark:hover:text-red-400 focus-ring"
                aria-label="Remove passkey"
              >
                <Trash2 className="h-4 w-4" />
              </button>
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}
