import { useEffect, useState } from "react";
import { Link, useLocation } from "wouter";
import { ArrowLeft } from "lucide-react";
import { useTranslation } from "react-i18next";
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
  const { t } = useTranslation("auth");
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
          <Link
            href="/login"
            className="inline-flex items-center gap-1.5 text-sm font-medium text-muted-foreground transition-colors hover:text-foreground"
          >
            <ArrowLeft className="h-4 w-4 rtl:rotate-180" /> {t("backToSignIn")}
          </Link>
          <div>
            <h2 className="font-display text-2xl font-bold tracking-tight text-foreground">
              {t("register.title")}
            </h2>
            <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
              {t("register.subtitle")}
            </p>
          </div>

          <SignUpForm
            onRegistered={(email, rememberMe) => setStep({ kind: "verify", email, rememberMe })}
          />

          <p className="text-center text-sm text-muted-foreground">
            {t("register.haveAccount")}{" "}
            <Link href="/login" className="font-semibold text-jade-600 hover:text-jade-700 dark:text-jade-400">
              {t("signIn.action")}
            </Link>
          </p>
        </div>
      )}
    </AuthShell>
  );
}
