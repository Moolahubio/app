import { useState } from "react";
import { Link } from "wouter";
import { EmailPasswordForm } from "./EmailPasswordForm";
import { PasskeySignIn } from "./AuthForm";
import { TwoFactorStep } from "./TwoFactorStep";
import { VerifyEmailStep } from "./VerifyEmailStep";

type Step =
  | { kind: "login" }
  | { kind: "verify"; email: string; rememberMe: boolean }
  | { kind: "twofactor"; challengeId: string };

export function AuthPanel() {
  const [step, setStep] = useState<Step>({ kind: "login" });

  if (step.kind === "twofactor") {
    return (
      <TwoFactorStep
        challengeId={step.challengeId}
        onCancel={() => setStep({ kind: "login" })}
      />
    );
  }

  if (step.kind === "verify") {
    return (
      <VerifyEmailStep
        email={step.email}
        rememberMe={step.rememberMe}
        onTwoFactorRequired={(challengeId) => setStep({ kind: "twofactor", challengeId })}
        onCancel={() => setStep({ kind: "login" })}
      />
    );
  }

  return (
    <div className="space-y-5">
      <div>
        <h2 className="font-display text-2xl font-bold tracking-tight text-foreground">
          Welcome back
        </h2>
        <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
          Sign in to keep saving toward your goals.
        </p>
      </div>

      <EmailPasswordForm
        onTwoFactorRequired={(challengeId) => setStep({ kind: "twofactor", challengeId })}
        onVerifyRequired={(email, rememberMe) => setStep({ kind: "verify", email, rememberMe })}
      />

      <div className="flex items-center gap-4">
        <span className="h-px flex-1 bg-border" />
        <span className="font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
          or
        </span>
        <span className="h-px flex-1 bg-border" />
      </div>

      <PasskeySignIn onTwoFactorRequired={(challengeId) => setStep({ kind: "twofactor", challengeId })} />

      <p className="text-center text-sm text-muted-foreground">
        New to MoolaHub?{" "}
        <Link href="/register" className="font-semibold text-jade-600 hover:text-jade-700 dark:text-jade-400">
          Create an account
        </Link>
      </p>
    </div>
  );
}
