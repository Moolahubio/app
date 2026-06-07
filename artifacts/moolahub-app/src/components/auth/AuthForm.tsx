import { useState } from "react";
import { AlertCircle, Fingerprint } from "lucide-react";
import { startAuthentication, browserSupportsWebAuthn } from "@simplewebauthn/browser";
import type { PublicKeyCredentialRequestOptionsJSON } from "@simplewebauthn/browser";
import { Button } from "@/components/ui";
import {
  useLoginPasskeyOptions,
  useLoginPasskeyVerify,
  getGetMeQueryKey,
} from "@workspace/api-client-react";
import { apiErrorMessage } from "@/lib/utils";
import { useLocation } from "wouter";
import { useQueryClient } from "@tanstack/react-query";

export function PasskeySignIn({
  onTwoFactorRequired,
}: {
  onTwoFactorRequired: (challengeId: string) => void;
}) {
  const [, setLocation] = useLocation();
  const queryClient = useQueryClient();
  const [passkeyError, setPasskeyError] = useState<string | null>(null);

  const passkeyOptions = useLoginPasskeyOptions();
  const passkeyVerify = useLoginPasskeyVerify();
  const passkeyPending = passkeyOptions.isPending || passkeyVerify.isPending;

  const handlePasskeyLogin = async () => {
    setPasskeyError(null);
    try {
      const { flowId, options } = await passkeyOptions.mutateAsync();
      const response = await startAuthentication({
        optionsJSON: options as unknown as PublicKeyCredentialRequestOptionsJSON,
      });
      const result = await passkeyVerify.mutateAsync({
        data: { flowId, response: response as unknown as Record<string, unknown> },
      });
      if (result.twoFactorRequired) {
        if (result.challengeId) {
          onTwoFactorRequired(result.challengeId);
        } else {
          setPasskeyError("We couldn't start two-factor verification. Please try again.");
        }
        return;
      }
      queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() });
      setLocation("/");
    } catch (err) {
      if (err instanceof Error && err.name === "NotAllowedError") {
        setPasskeyError("Sign-in cancelled.");
      } else {
        setPasskeyError(apiErrorMessage(err) ?? "We couldn't sign you in. Please try again.");
      }
    }
  };

  if (!browserSupportsWebAuthn()) return null;

  return (
    <div>
      <Button
        type="button"
        size="lg"
        variant="secondary"
        className="w-full"
        disabled={passkeyPending}
        onClick={handlePasskeyLogin}
      >
        <Fingerprint className="h-4 w-4" />
        {passkeyPending ? "Verifying…" : "Sign in with passkey"}
      </Button>

      {passkeyError && (
        <p className="mt-3 flex items-center gap-1.5 text-sm text-red-600" role="alert">
          <AlertCircle className="h-4 w-4 shrink-0" /> {passkeyError}
        </p>
      )}
    </div>
  );
}
