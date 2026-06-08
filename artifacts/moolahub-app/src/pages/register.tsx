import { useEffect, useState } from "react";
import { Link, useLocation } from "wouter";
import { AuthShell } from "@/components/auth/AuthShell";
import { SignUpForm } from "@/components/auth/SignUpForm";
import { VerifyEmailStep } from "@/components/auth/VerifyEmailStep";
import { TwoFactorStep } from "@/components/auth/TwoFactorStep";
import { useAuth } from "@/hooks/use-auth";

type Step =
  | { kind: "signup" }
  | { kind: "verify"; email: string; rememberMe: boolean }
  | { kind: "twofactor"; challengeId: string };

export default function Register() {
  const { isAuthenticated, isLoading } = useAuth();
  const [, setLocation] = useLocation();
  const [step, setStep] = useState<Step>({ kind: "signup" });

  useEffect(() => {
    if (!isLoading && isAuthenticated) {
      setLocation("/");
    }
  }, [isLoading, isAuthenticated, setLocation]);

  if (!isLoading && isAuthenticated) {
    return null;
  }

  return (
    <AuthShell>
      {step.kind === "twofactor" ? (
        <TwoFactorStep
          challengeId={step.challengeId}
          onCancel={() => setStep({ kind: "signup" })}
        />
      ) : step.kind === "verify" ? (
        <VerifyEmailStep
          email={step.email}
          rememberMe={step.rememberMe}
          onTwoFactorRequired={(challengeId) => setStep({ kind: "twofactor", challengeId })}
          onCancel={() => setStep({ kind: "signup" })}
        />
      ) : (
        <div className="space-y-5">
          <div>
            <h2 className="font-display text-2xl font-bold tracking-tight text-foreground">
              Create your account
            </h2>
            <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
              Save smarter, together. It only takes a minute.
            </p>
          </div>

          <SignUpForm
            onRegistered={(email, rememberMe) => setStep({ kind: "verify", email, rememberMe })}
          />

          <p className="text-center text-sm text-muted-foreground">
            Already have an account?{" "}
            <Link href="/login" className="font-semibold text-jade-600 hover:text-jade-700 dark:text-jade-400">
              Sign in
            </Link>
          </p>
        </div>
      )}
    </AuthShell>
  );
}
