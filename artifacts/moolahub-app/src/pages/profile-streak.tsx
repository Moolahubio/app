import { useState } from "react";
import { Check, AlertCircle, Flame, Lock } from "lucide-react";
import { Badge } from "@/components/ui";
import { PageHeader, BackLink } from "@/components/app/bits";
import { useStreak, getGetStreaksQueryKey } from "@/hooks/use-streak";
import { useSetStreakFrequency } from "@workspace/api-client-react";
import { useQueryClient } from "@tanstack/react-query";
import { apiErrorMessage, cn } from "@/lib/utils";
import { useTranslation } from "react-i18next";

type Frequency = "daily" | "weekly" | "monthly";

const OPTIONS: { key: Frequency; recommended?: boolean }[] = [
  { key: "daily" },
  { key: "weekly", recommended: true },
  { key: "monthly" },
];

export default function ProfileStreakPage() {
  const { t } = useTranslation("streak");
  const { data, isLoading } = useStreak();
  const setFrequency = useSetStreakFrequency();
  const queryClient = useQueryClient();

  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  if (isLoading)
    return <div className="p-8 text-center text-muted-foreground">{t("common:actions.loading")}</div>;
  if (!data) return null;

  const current = data.frequency as Frequency;
  const canChange = data.canChangeFrequency;

  const select = async (freq: Frequency) => {
    if (freq === current || !canChange || setFrequency.isPending) return;
    setError(null);
    try {
      await setFrequency.mutateAsync({ data: { frequency: freq } });
      await queryClient.invalidateQueries({ queryKey: getGetStreaksQueryKey() });
      setSaved(true);
      setTimeout(() => setSaved(false), 1800);
    } catch (err) {
      setError(apiErrorMessage(err) ?? t("profile.frequencyError"));
    }
  };

  return (
    <div className="mx-auto max-w-2xl space-y-6">
      <BackLink href="/profile" label={t("common:nav.account")} />
      <PageHeader
        eyebrow={t("eyebrow")}
        title={t("profile.title")}
        description={t("profile.description")}
      />

      {error && (
        <p className="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
          <AlertCircle className="h-4 w-4 shrink-0" /> {error}
        </p>
      )}
      {saved && (
        <p className="flex items-center gap-1.5 text-sm text-jade-600 dark:text-jade-400">
          <Check className="h-4 w-4 shrink-0" /> {t("common:actions.saved")}
        </p>
      )}

      <div className="space-y-3">
        {OPTIONS.map((opt) => {
          const active = current === opt.key;
          return (
            <button
              key={opt.key}
              type="button"
              onClick={() => select(opt.key)}
              disabled={!canChange && !active}
              className={cn(
                "w-full rounded-2xl border bg-card p-4 text-start transition-colors focus-ring",
                active
                  ? "border-jade-500 ring-1 ring-jade-500/40"
                  : canChange
                    ? "border-card-border hover:bg-accent"
                    : "border-card-border opacity-60",
              )}
            >
              <div className="flex items-center justify-between gap-3">
                <div className="flex items-center gap-2">
                  <Flame className="h-4 w-4 text-jade-600 dark:text-jade-400" />
                  <span className="text-sm font-semibold text-foreground">
                    {t(`profile.options.${opt.key}.label`)}
                  </span>
                  {opt.recommended && <Badge tone="jade">{t("profile.recommended")}</Badge>}
                </div>
                {active && (
                  <span className="flex h-5 w-5 items-center justify-center rounded-full bg-jade-500 text-white">
                    <Check className="h-3.5 w-3.5" />
                  </span>
                )}
              </div>
              <p className="mt-1 text-xs text-muted-foreground">
                {t(`profile.options.${opt.key}.description`)}
              </p>
            </button>
          );
        })}
      </div>

      {!canChange && (
        <div className="flex items-start gap-2 rounded-2xl border border-border bg-muted/40 p-4 text-sm text-muted-foreground">
          <Lock className="mt-0.5 h-4 w-4 shrink-0" />
          <p>
            {data.nextChangeYear
              ? t("profile.lockNoteNext", { year: data.nextChangeYear })
              : t("profile.lockNote")}
          </p>
        </div>
      )}
    </div>
  );
}
