import { useEffect, useState } from "react";
import { AlertCircle, Eye, EyeOff, Check, Loader2 } from "lucide-react";
import { Button } from "@/components/ui";
import { useRegister, useUsernameAvailable, getUsernameAvailableQueryKey } from "@workspace/api-client-react";
import { apiErrorMessage } from "@/lib/utils";
import { authInputClass } from "./AuthShell";

const REFERRAL_SOURCES = [
  "Twitter",
  "Telegram",
  "WhatsApp",
  "Discord",
  "LinkedIn",
  "Friends",
  "Others",
];

const USERNAME_RE = /^[a-zA-Z0-9_]{3,30}$/;

export function SignUpForm({ onRegistered }: { onRegistered: (email: string, rememberMe: boolean) => void }) {
  const register = useRegister();

  const [name, setName] = useState("");
  const [username, setUsername] = useState("");
  const [dateOfBirth, setDateOfBirth] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [referralSource, setReferralSource] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [rememberMe, setRememberMe] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Live username availability (debounced).
  const [debounced, setDebounced] = useState("");
  useEffect(() => {
    const t = setTimeout(() => setDebounced(username.trim().toLowerCase()), 400);
    return () => clearTimeout(t);
  }, [username]);

  const usernameValid = USERNAME_RE.test(debounced);
  const availability = useUsernameAvailable(
    { username: debounced },
    { query: { enabled: usernameValid, retry: false, queryKey: getUsernameAvailableQueryKey({ username: debounced }) } },
  );

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);

    const trimmedName = name.trim();
    const trimmedUser = username.trim().toLowerCase();
    const trimmedEmail = email.trim().toLowerCase();

    if (!trimmedName) return setError("Please enter your legal name.");
    if (!USERNAME_RE.test(trimmedUser))
      return setError("Username must be 3–30 characters: letters, numbers, or underscores.");
    if (!dateOfBirth) return setError("Please enter your date of birth.");
    if (new Date(`${dateOfBirth}T00:00:00Z`).getTime() >= Date.now())
      return setError("Please enter a valid date of birth.");
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(trimmedEmail))
      return setError("Please enter a valid email address.");
    if (password.length < 8) return setError("Password must be at least 8 characters.");
    if (password !== confirm) return setError("Passwords don't match.");

    try {
      await register.mutateAsync({
        data: {
          name: trimmedName,
          username: trimmedUser,
          email: trimmedEmail,
          password,
          dateOfBirth,
          referralSource: referralSource || null,
          rememberMe,
        },
      });
      onRegistered(trimmedEmail, rememberMe);
    } catch (err) {
      setError(apiErrorMessage(err) ?? "Could not create your account. Please try again.");
    }
  };

  const usernameStatus = !debounced
    ? null
    : !usernameValid
      ? { ok: false, text: "3–30 letters, numbers, or underscores" }
      : availability.isFetching
        ? { ok: null, text: "Checking…" }
        : availability.data
          ? availability.data.available
            ? { ok: true, text: "Available" }
            : { ok: false, text: availability.data.reason ?? "Taken" }
          : null;

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <label className="block">
        <span className="text-sm font-medium text-foreground">
          Legal name <span className="text-xs font-normal text-muted-foreground">· private</span>
        </span>
        <input
          autoComplete="name"
          required
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Jane Doe"
          className={`mt-1.5 ${authInputClass}`}
        />
      </label>

      <label className="block">
        <span className="text-sm font-medium text-foreground">
          Username <span className="text-xs font-normal text-muted-foreground">· public</span>
        </span>
        <input
          autoCapitalize="none"
          autoComplete="username"
          required
          value={username}
          onChange={(e) => setUsername(e.target.value)}
          placeholder="janedoe"
          className={`mt-1.5 ${authInputClass}`}
        />
        {usernameStatus && (
          <span
            className={`mt-1 flex items-center gap-1 text-xs ${
              usernameStatus.ok === true
                ? "text-jade-600 dark:text-jade-400"
                : usernameStatus.ok === false
                  ? "text-red-600 dark:text-red-400"
                  : "text-muted-foreground"
            }`}
          >
            {usernameStatus.ok === true && <Check className="h-3 w-3" />}
            {usernameStatus.ok === null && <Loader2 className="h-3 w-3 animate-spin" />}
            {usernameStatus.text}
          </span>
        )}
      </label>

      <label className="block">
        <span className="text-sm font-medium text-foreground">Date of birth</span>
        <input
          type="date"
          required
          value={dateOfBirth}
          onChange={(e) => setDateOfBirth(e.target.value)}
          className={`mt-1.5 ${authInputClass}`}
        />
      </label>

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
            autoComplete="new-password"
            required
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            placeholder="At least 8 characters"
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

      <label className="block">
        <span className="text-sm font-medium text-foreground">Confirm password</span>
        <input
          type={showPassword ? "text" : "password"}
          autoComplete="new-password"
          required
          value={confirm}
          onChange={(e) => setConfirm(e.target.value)}
          placeholder="Re-enter your password"
          className={`mt-1.5 ${authInputClass}`}
        />
      </label>

      <label className="block">
        <span className="text-sm font-medium text-foreground">
          How did you hear about MoolaHub?{" "}
          <span className="text-xs font-normal text-muted-foreground">· optional</span>
        </span>
        <select
          value={referralSource}
          onChange={(e) => setReferralSource(e.target.value)}
          className={`mt-1.5 ${authInputClass}`}
        >
          <option value="">Select one…</option>
          {REFERRAL_SOURCES.map((s) => (
            <option key={s} value={s}>
              {s}
            </option>
          ))}
        </select>
      </label>

      <label className="flex items-center gap-2 text-sm text-muted-foreground">
        <input
          type="checkbox"
          checked={rememberMe}
          onChange={(e) => setRememberMe(e.target.checked)}
          className="h-4 w-4 rounded border-border"
        />
        Keep me logged in for 30 days
      </label>

      {error && (
        <p className="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
          <AlertCircle className="h-4 w-4 shrink-0" /> {error}
        </p>
      )}

      <Button type="submit" size="lg" className="w-full" disabled={register.isPending}>
        {register.isPending ? "Creating account…" : "Create account"}
      </Button>
    </form>
  );
}
