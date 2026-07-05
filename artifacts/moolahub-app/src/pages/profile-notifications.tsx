import { useEffect, useState } from "react";
import { Check, AlertCircle } from "lucide-react";
import { Card, Badge } from "@/components/ui";
import { Switch } from "@/components/ui/switch";
import { PageHeader, BackLink } from "@/components/app/bits";
import {
  useGetNotificationPreferences,
  useUpdateNotificationPreferences,
  getGetNotificationPreferencesQueryKey,
  type NotificationCategories,
} from "@workspace/api-client-react";
import { useQueryClient } from "@tanstack/react-query";
import { apiErrorMessage, cn } from "@/lib/utils";
import { useTranslation } from "react-i18next";

type Tier = "everything" | "essential" | "minimal" | "custom";

const TIERS: {
  key: Tier;
  recommended?: boolean;
}[] = [
  { key: "everything", recommended: true },
  { key: "essential" },
  { key: "minimal" },
  { key: "custom" },
];

const CATEGORIES: {
  key: keyof NotificationCategories;
}[] = [
  { key: "money" },
  { key: "social" },
  { key: "engagement" },
];

export default function ProfileNotificationsPage() {
  const { t } = useTranslation("notifications");
  const { data, isLoading } = useGetNotificationPreferences();
  const updatePrefs = useUpdateNotificationPreferences();
  const queryClient = useQueryClient();

  const [preference, setPreference] = useState<Tier>("everything");
  const [categories, setCategories] = useState<NotificationCategories>({
    money: true,
    social: true,
    engagement: true,
  });
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    if (data) {
      setPreference((data.preference as Tier) ?? "everything");
      setCategories(data.categories);
    }
  }, [data]);

  const invalidate = () =>
    queryClient.invalidateQueries({
      queryKey: getGetNotificationPreferencesQueryKey(),
    });

  const flash = () => {
    setSaved(true);
    setTimeout(() => setSaved(false), 1500);
  };

  const selectTier = async (tier: Tier) => {
    if (tier === preference && tier !== "custom") return;
    setError(null);
    setPreference(tier);
    try {
      await updatePrefs.mutateAsync({ data: { preference: tier } });
      await invalidate();
      flash();
    } catch (err) {
      setError(apiErrorMessage(err) ?? t("settings.saveError"));
    }
  };

  const toggleCategory = async (key: keyof NotificationCategories, value: boolean) => {
    setError(null);
    const next = { ...categories, [key]: value };
    setCategories(next);
    setPreference("custom");
    try {
      await updatePrefs.mutateAsync({
        data: { preference: "custom", categories: next },
      });
      await invalidate();
      flash();
    } catch (err) {
      setError(apiErrorMessage(err) ?? t("settings.saveError"));
    }
  };

  if (isLoading)
    return <div className="p-8 text-center text-muted-foreground">{t("common:actions.loading")}</div>;

  return (
    <div className="mx-auto max-w-2xl space-y-6">
      <BackLink href="/profile" label={t("common:nav.account")} />
      <PageHeader
        eyebrow={t("page.eyebrow")}
        title={t("settings.title")}
        description={t("settings.description")}
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
        {TIERS.map((tier) => {
          const active = preference === tier.key;
          return (
            <button
              key={tier.key}
              type="button"
              onClick={() => selectTier(tier.key)}
              className={cn(
                "w-full rounded-2xl border bg-card p-4 text-start transition-colors focus-ring",
                active
                  ? "border-jade-500 ring-1 ring-jade-500/40"
                  : "border-card-border hover:bg-accent",
              )}
            >
              <div className="flex items-center justify-between gap-3">
                <div className="flex items-center gap-2">
                  <span className="text-sm font-semibold text-foreground">{t(`tiers.${tier.key}.label`)}</span>
                  {tier.recommended && <Badge tone="jade">{t("settings.recommended")}</Badge>}
                </div>
                {active && (
                  <span className="flex h-5 w-5 items-center justify-center rounded-full bg-jade-500 text-white">
                    <Check className="h-3.5 w-3.5" />
                  </span>
                )}
              </div>
              <p className="mt-1 text-xs text-muted-foreground">{t(`tiers.${tier.key}.description`)}</p>
            </button>
          );
        })}
      </div>

      {preference === "custom" && (
        <Card className="divide-y divide-border p-1">
          {CATEGORIES.map((cat) => (
            <div key={cat.key} className="flex items-center justify-between gap-4 px-4 py-3.5">
              <div className="min-w-0">
                <p className="text-sm font-semibold text-foreground">{t(`categories.${cat.key}.label`)}</p>
                <p className="text-xs text-muted-foreground">{t(`categories.${cat.key}.description`)}</p>
              </div>
              <Switch
                checked={categories[cat.key]}
                onCheckedChange={(v: boolean) => toggleCategory(cat.key, v)}
                disabled={updatePrefs.isPending}
              />
            </div>
          ))}
        </Card>
      )}
    </div>
  );
}
