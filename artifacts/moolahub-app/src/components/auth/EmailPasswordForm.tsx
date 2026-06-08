import { useState } from "react";
import { AlertCircle, Eye, EyeOff } from "lucide-react";
import { useLocation } from "wouter";
import { useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui";
import { useLogin, getGetMeQueryKey } from "@workspace/api-client-react";
import { apiErrorMessage } from "@/lib/utils";
import { authInputClass } from "./AuthShell";

export function EmailPasswordForm({
  onTwoFactorRequired,
  onVerifyRequired,
  onForgotPassword,
}: {
  onTwoFactorRequired: (challengeId: string) => void;
  onVerifyRequired: (email: string, rememberMe: boolean) => void;
  onForgotPassword: (email: string) => void;
}) {
  const [, setLocation] = useLocation();
  const queryClient = useQueryClient();
  const login = useLogin();

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [rememberMe, setRememberMe] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    try {
      const result = await login.mutateAsync({
        data: { email: email.trim(), password, rememberMe },
      });
      if (result.emailVerificationRequired) {
        onVerifyRequired(email.trim(), rememberMe);
        return;
      }
      if (result.twoFactorRequired) {
        if (result.challengeId) onTwoFactorRequired(result.challengeId);
        else setError("We couldn't start verification. Please try again.");
        return;
      }
      queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() });
      setLocation("/");
    } catch (err) {
      setError(apiErrorMessage(err) ?? "Invalid email or password.");
    }
  };

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <label className="block">
        <span className="text-sm font-medium text-foreground">Email</span>
        <input
          type="email"
          autoComplete="email"
          required
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder="you@example.com"
          className={`mt-1.5 ${authInputClass}`}
        />
      </label>

      <label className="block">
        <span className="text-sm font-medium text-foreground">Password</span>
        <div className="relative mt-1.5">
          <input
            type={showPassword ? "text" : "password"}
            autoComplete="current-password"
            required
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            placeholder="Your password"
            className={`${authInputClass} pr-10`}
          />
          <button
            type="button"
            onClick={() => setShowPassword((s) => !s)}
            className="absolute inset-y-0 right-0 flex items-center px-3 text-muted-foreground hover:text-foreground focus-ring"
            aria-label={showPassword ? "Hide password" : "Show password"}
          >
            {showPassword ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
          </button>
        </div>
      </label>

      <div className="flex items-center justify-between gap-3">
        <label className="flex items-center gap-2 text-sm text-muted-foreground">
          <input
            type="checkbox"
            checked={rememberMe}
            onChange={(e) => setRememberMe(e.target.checked)}
            className="h-4 w-4 rounded border-border"
          />
          Keep me logged in for 30 days
        </label>
        <button
          type="button"
          onClick={() => onForgotPassword(email.trim())}
          className="text-sm font-medium text-jade-600 transition-colors hover:text-jade-700 dark:text-jade-400"
        >
          Forgot password?
        </button>
      </div>

      {error && (
        <p className="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
          <AlertCircle className="h-4 w-4 shrink-0" /> {error}
        </p>
      )}

      <Button
        type="submit"
        size="lg"
        className="w-full"
        disabled={login.isPending || !email.trim() || !password}
      >
        {login.isPending ? "Signing in…" : "Sign in"}
      </Button>
    </form>
  );
}
