import { useEffect, useState } from "react";
import { useLocation } from "wouter";
import { useTranslation } from "react-i18next";
import { AlertCircle, Eye, EyeOff, Check, Loader2, LogOut } from "lucide-react";
import { AuthShell } from "@/components/auth/AuthShell";
import { authInputClass } from "@/components/auth/AuthShell";
import { Button } from "@/components/ui";
import {
  useGetMe,
  useUpdateProfile,
  useChangePassword,
  useUsernameAvailable,
  useLogout,
  getUsernameAvailableQueryKey,
  getGetMeQueryKey,
  getGetProfileQueryKey,
} from "@workspace/api-client-react";
import { useQueryClient } from "@tanstack/react-query";
import { apiErrorMessage } from "@/lib/utils";

const USERNAME_RE = /^[a-zA-Z0-9_]{3,30}$/;

export default function CompleteProfile() {
  const { t } = useTranslation("auth");
  const { data: user, isLoading } = useGetMe();
  const updateProfile = useUpdateProfile();
  const changePassword = useChangePassword();
  const logout = useLogout();
  const queryClient = useQueryClient();
  const [, setLocation] = useLocation();

  const handleSignOut = () => {
    logout.mutate(undefined, {
      onSuccess: () => {
        queryClient.setQueryData(getGetMeQueryKey(), null);
        queryClient.removeQueries({
          predicate: (q) => q.queryKey[0] !== getGetMeQueryKey()[0],
        });
        setLocation("/login");
      },
    });
  };

  const needsUsername = !!user && !user.username;
  const needsPassword = !!user && !user.hasPassword;

  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [show, setShow] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const [debounced, setDebounced] = useState("");
  useEffect(() => {
    const t = setTimeout(() => setDebounced(username.trim().toLowerCase()), 400);
    return () => clearTimeout(t);
  }, [username]);

  const usernameValid = USERNAME_RE.test(debounced);
  const availability = useUsernameAvailable(
    { username: debounced },
    { query: { enabled: needsUsername && usernameValid, retry: false, queryKey: getUsernameAvailableQueryKey({ username: debounced }) } },
  );

  // Redirect away once there's nothing left to complete.
  useEffect(() => {
    if (!isLoading && user && user.username && user.hasPassword) {
      setLocation("/");
    }
    if (!isLoading && !user) {
      setLocation("/login");
    }
  }, [isLoading, user, setLocation]);

  if (isLoading || !user) {
    return null;
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);

    if (needsUsername) {
      const u = username.trim().toLowerCase();
      if (!USERNAME_RE.test(u))
        return setError(t("errors.username"));
    }
    if (needsPassword) {
      if (password.length < 8) return setError(t("errors.passwordLength"));
      if (password !== confirm) return setError(t("errors.passwordMatch"));
    }

    setSubmitting(true);
    try {
      if (needsUsername) {
        await updateProfile.mutateAsync({ data: { username: username.trim().toLowerCase() } });
      }
      if (needsPassword) {
        await changePassword.mutateAsync({ data: { currentPassword: null, newPassword: password } });
      }
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() }),
        queryClient.invalidateQueries({ queryKey: getGetProfileQueryKey() }),
      ]);
      setLocation("/");
    } catch (err) {
      setError(apiErrorMessage(err) ?? t("errors.saveDetails"));
    } finally {
      setSubmitting(false);
    }
  };

  const usernameStatus = !needsUsername || !debounced
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
    <AuthShell>
      <div className="space-y-5">
        <button
          type="button"
          onClick={handleSignOut}
          disabled={logout.isPending}
          className="inline-flex items-center gap-1.5 text-sm font-medium text-muted-foreground transition-colors hover:text-foreground focus-ring disabled:opacity-60"
        >
          <LogOut className="h-4 w-4" /> {logout.isPending ? t("common:actions.signingOut") : t("common:actions.signOut")}
        </button>
        <div>
          <h2 className="font-display text-2xl font-bold tracking-tight text-foreground">
            {t("complete.title")}
          </h2>
          <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
            {t("complete.subtitle")}
          </p>
        </div>

        <form onSubmit={handleSubmit} className="space-y-4">
          {needsUsername && (
            <label className="block">
              <span className="text-sm font-medium text-foreground">
                {t("fields.username")} <span className="text-xs font-normal text-muted-foreground">{t("fields.public")}</span>
              </span>
              <input
                autoCapitalize="none"
                autoComplete="username"
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
          )}

          {needsPassword && (
            <>
              <label className="block">
                <span className="text-sm font-medium text-foreground">{t("fields.password")}</span>
                <div className="relative mt-1.5">
                  <input
                    type={show ? "text" : "password"}
                    autoComplete="new-password"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    placeholder={t("fields.passwordMinPlaceholder")}
                    className={`${authInputClass} pe-10`}
                  />
                  <button
                    type="button"
                    onClick={() => setShow((s) => !s)}
                    className="absolute inset-y-0 end-0 flex items-center px-3 text-muted-foreground hover:text-foreground focus-ring"
                    aria-label={show ? t("password.hide") : t("password.show")}
                  >
                    {show ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                  </button>
                </div>
              </label>
              <label className="block">
                <span className="text-sm font-medium text-foreground">{t("fields.confirmPassword")}</span>
                <input
                  type={show ? "text" : "password"}
                  autoComplete="new-password"
                  value={confirm}
                  onChange={(e) => setConfirm(e.target.value)}
                  className={`mt-1.5 ${authInputClass}`}
                />
              </label>
            </>
          )}

          {error && (
            <p className="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
              <AlertCircle className="h-4 w-4 shrink-0" /> {error}
            </p>
          )}

          <Button type="submit" size="lg" className="w-full" disabled={submitting}>
            {submitting ? t("complete.submitting") : t("complete.submit")}
          </Button>
        </form>
      </div>
    </AuthShell>
  );
}
