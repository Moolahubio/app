import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
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
  const { t } = useTranslation("auth");
  const register = useRegister();

  const [name, setName] = useState("");
  const [username, setUsername] = useState("");
  const [dateOfBirth, setDateOfBirth] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [referralSource, setReferralSource] = useState("");
  const [referralCode, setReferralCode] = useState<string | null>(null);
  const [showPassword, setShowPassword] = useState(false);
  const [rememberMe, setRememberMe] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Capture an invite code from the sign-up link (?ref=CODE) so the new
  // account is attributed to the referrer on registration.
  useEffect(() => {
    const code = new URLSearchParams(window.location.search).get("ref");
    if (code && code.trim()) setReferralCode(code.trim().toUpperCase());
  }, []);

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

    if (!trimmedName) return setError(t("errors.name"));
    if (!USERNAME_RE.test(trimmedUser))
      return setError(t("errors.username"));
    if (!dateOfBirth) return setError(t("errors.dobRequired"));
    if (new Date(`${dateOfBirth}T00:00:00Z`).getTime() >= Date.now())
      return setError(t("errors.dobInvalid"));
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(trimmedEmail))
      return setError(t("errors.email"));
    if (password.length < 8) return setError(t("errors.passwordLength"));
    if (password !== confirm) return setError(t("errors.passwordMatch"));

    try {
      await register.mutateAsync({
        data: {
          name: trimmedName,
          username: trimmedUser,
          email: trimmedEmail,
          password,
          dateOfBirth,
          referralSource: referralSource || null,
          referralCode: referralCode || null,
          rememberMe,
        },
      });
      onRegistered(trimmedEmail, rememberMe);
    } catch (err) {
      setError(apiErrorMessage(err) ?? t("errors.createAccount"));
    }
  };

  const usernameStatus = !debounced
    ? null
    : !usernameValid
      ? { ok: false, text: t("username.hint") }
      : availability.isFetching
        ? { ok: null, text: t("username.checking") }
        : availability.data
          ? availability.data.available
            ? { ok: true, text: t("username.available") }
            : { ok: false, text: availability.data.reason ?? t("username.taken") }
          : null;

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <label className="block">
        <span className="text-sm font-medium text-foreground">
          {t("fields.legalName")} <span className="text-xs font-normal text-muted-foreground">{t("fields.private")}</span>
        </span>
        <input
          autoComplete="name"
          required
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder={t("fields.namePlaceholder")}
          className={`mt-1.5 ${authInputClass}`}
        />
      </label>

      <label className="block">
        <span className="text-sm font-medium text-foreground">
          {t("fields.username")} <span className="text-xs font-normal text-muted-foreground">{t("fields.public")}</span>
        </span>
        <input
          autoCapitalize="none"
          autoComplete="username"
          required
          value={username}
          onChange={(e) => setUsername(e.target.value)}
          placeholder={t("fields.usernamePlaceholder")}
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
        <span className="text-sm font-medium text-foreground">{t("fields.dateOfBirth")}</span>
        <input
          type="date"
          required
          value={dateOfBirth}
          onChange={(e) => setDateOfBirth(e.target.value)}
          className={`mt-1.5 ${authInputClass}`}
        />
      </label>

      <label className="block">
        <span className="text-sm font-medium text-foreground">{t("fields.email")}</span>
        <input
          type="email"
          autoComplete="email"
          required
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder={t("fields.emailPlaceholder")}
          className={`mt-1.5 ${authInputClass}`}
        />
      </label>

      <label className="block">
        <span className="text-sm font-medium text-foreground">{t("fields.password")}</span>
        <div className="relative mt-1.5">
          <input
            type={showPassword ? "text" : "password"}
            autoComplete="new-password"
            required
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            placeholder={t("fields.passwordMinPlaceholder")}
            className={`${authInputClass} pe-10`}
          />
          <button
            type="button"
            onClick={() => setShowPassword((s) => !s)}
            className="absolute inset-y-0 end-0 flex items-center px-3 text-muted-foreground hover:text-foreground focus-ring"
            aria-label={showPassword ? t("password.hide") : t("password.show")}
          >
            {showPassword ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
          </button>
        </div>
      </label>

      <label className="block">
        <span className="text-sm font-medium text-foreground">{t("fields.confirmPassword")}</span>
        <input
          type={showPassword ? "text" : "password"}
          autoComplete="new-password"
          required
          value={confirm}
          onChange={(e) => setConfirm(e.target.value)}
          placeholder={t("fields.confirmPasswordPlaceholder")}
          className={`mt-1.5 ${authInputClass}`}
        />
      </label>

      <label className="block">
        <span className="text-sm font-medium text-foreground">
          {t("signUp.referralLabel")}{" "}
          <span className="text-xs font-normal text-muted-foreground">{t("fields.optional")}</span>
        </span>
        <select
          value={referralSource}
          onChange={(e) => setReferralSource(e.target.value)}
          className={`mt-1.5 ${authInputClass}`}
        >
          <option value="">{t("signUp.referralPlaceholder")}</option>
          {REFERRAL_SOURCES.map((s) => (
            <option key={s} value={s}>
              {t(`signUp.sources.${s}`)}
            </option>
          ))}
        </select>
      </label>

      <label className="block">
        <span className="text-sm font-medium text-foreground">
          {t("signUp.inviteLabel")}{" "}
          <span className="text-xs font-normal text-muted-foreground">{t("fields.optional")}</span>
        </span>
        <input
          autoCapitalize="characters"
          autoComplete="off"
          value={referralCode ?? ""}
          onChange={(e) => setReferralCode(e.target.value.toUpperCase() || null)}
          placeholder={t("signUp.invitePlaceholder")}
          className={`mt-1.5 ${authInputClass}`}
        />
        {referralCode && (
          <span className="mt-1 flex items-center gap-1 text-xs text-jade-600 dark:text-jade-400">
            <Check className="h-3 w-3" /> {t("referrals:signup.invited")}
          </span>
        )}
      </label>

      <label className="flex items-center gap-2 text-sm text-muted-foreground">
        <input
          type="checkbox"
          checked={rememberMe}
          onChange={(e) => setRememberMe(e.target.checked)}
          className="h-4 w-4 rounded border-border"
        />
        {t("rememberMe")}
      </label>

      {error && (
        <p className="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
          <AlertCircle className="h-4 w-4 shrink-0" /> {error}
        </p>
      )}

      <Button type="submit" size="lg" className="w-full" disabled={register.isPending}>
        {register.isPending ? t("signUp.submitting") : t("signUp.submit")}
      </Button>
    </form>
  );
}
