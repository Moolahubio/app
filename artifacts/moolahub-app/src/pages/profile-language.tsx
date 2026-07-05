import { useState } from "react";
import { Check, AlertCircle } from "lucide-react";
import { useTranslation } from "react-i18next";
import { PageHeader, BackLink } from "@/components/app/bits";
import { useLanguageSetting } from "@/hooks/use-language-setting";
import { apiErrorMessage, cn } from "@/lib/utils";
import type { LanguageCode } from "@/i18n/languages";

export default function ProfileLanguagePage() {
  const { t } = useTranslation();
  const { language, languages, changeLanguage, isSaving } = useLanguageSetting();

  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  const select = async (code: LanguageCode) => {
    if (code === language || isSaving) return;
    setError(null);
    try {
      await changeLanguage(code);
      setSaved(true);
      setTimeout(() => setSaved(false), 1800);
    } catch (err) {
      setError(apiErrorMessage(err) ?? t("language.error"));
    }
  };

  return (
    <div className="mx-auto max-w-2xl space-y-6">
      <BackLink href="/profile" label={t("nav.account")} />
      <PageHeader
        eyebrow={t("language.eyebrow")}
        title={t("language.title")}
        description={t("language.description")}
      />

      {error && (
        <p className="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
          <AlertCircle className="h-4 w-4 shrink-0" /> {error}
        </p>
      )}
      {saved && (
        <p className="flex items-center gap-1.5 text-sm text-jade-600 dark:text-jade-400">
          <Check className="h-4 w-4 shrink-0" /> {t("actions.saved")}
        </p>
      )}

      <div className="space-y-3">
        {languages.map((lng) => {
          const active = language === lng.code;
          return (
            <button
              key={lng.code}
              type="button"
              dir={lng.dir}
              onClick={() => void select(lng.code)}
              disabled={isSaving && !active}
              className={cn(
                "w-full rounded-2xl border bg-card p-4 text-start transition-colors focus-ring",
                active
                  ? "border-jade-500 ring-1 ring-jade-500/40"
                  : "border-card-border hover:bg-accent",
                isSaving && !active && "opacity-60",
              )}
            >
              <div className="flex items-center justify-between gap-3">
                <div className="min-w-0">
                  <span className="block text-sm font-semibold text-foreground">
                    {lng.nativeName}
                  </span>
                  <span className="mt-0.5 block text-xs text-muted-foreground">
                    {t(`language.names.${lng.code}`)}
                  </span>
                </div>
                {active && (
                  <span className="flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-jade-500 text-white">
                    <Check className="h-3.5 w-3.5" />
                  </span>
                )}
              </div>
            </button>
          );
        })}
      </div>
    </div>
  );
}
