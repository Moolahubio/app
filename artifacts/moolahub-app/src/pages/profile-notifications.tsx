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

type Tier = "everything" | "essential" | "minimal" | "custom";

const TIERS: {
  key: Tier;
  label: string;
  description: string;
  recommended?: boolean;
}[] = [
  {
    key: "everything",
    label: "Everything",
    description:
      "All notifications — circle activity, goal milestones, deposits, reminders, and tips.",
    recommended: true,
  },
  {
    key: "essential",
    label: "Essential",
    description:
      "Important updates only, like payouts, contribution due dates, and account activity.",
  },
  {
    key: "minimal",
    label: "Minimal",
    description: "Only the most critical account and money notifications.",
  },
  {
    key: "custom",
    label: "Custom",
    description: "Choose exactly which categories you want to hear about.",
  },
];

const CATEGORIES: {
  key: keyof NotificationCategories;
  label: string;
  description: string;
}[] = [
  {
    key: "money",
    label: "Money & transactions",
    description: "Deposits, withdrawals, payouts, and contribution reminders.",
  },
  {
    key: "social",
    label: "Circles & social",
    description: "Invites, member activity, and circle updates.",
  },
  {
    key: "engagement",
    label: "Tips & engagement",
    description: "Streaks, learning nudges, and product news.",
  },
];

export default function ProfileNotificationsPage() {
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
      setError(apiErrorMessage(err) ?? "Could not save preference.");
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
      setError(apiErrorMessage(err) ?? "Could not save preference.");
    }
  };

  if (isLoading)
    return <div className="p-8 text-center text-muted-foreground">Loading…</div>;

  return (
    <div className="mx-auto max-w-2xl space-y-6">
      <BackLink href="/profile" label="Account" />
      <PageHeader
        eyebrow="Notifications"
        title="Notification settings"
        description="Choose how much you want to hear from MoolaHub."
      />

      {error && (
        <p className="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
          <AlertCircle className="h-4 w-4 shrink-0" /> {error}
        </p>
      )}
      {saved && (
        <p className="flex items-center gap-1.5 text-sm text-jade-600 dark:text-jade-400">
          <Check className="h-4 w-4 shrink-0" /> Saved.
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
                "w-full rounded-2xl border bg-card p-4 text-left transition-colors focus-ring",
                active
                  ? "border-jade-500 ring-1 ring-jade-500/40"
                  : "border-card-border hover:bg-accent",
              )}
            >
              <div className="flex items-center justify-between gap-3">
                <div className="flex items-center gap-2">
                  <span className="text-sm font-semibold text-foreground">{tier.label}</span>
                  {tier.recommended && <Badge tone="jade">Recommended</Badge>}
                </div>
                {active && (
                  <span className="flex h-5 w-5 items-center justify-center rounded-full bg-jade-500 text-white">
                    <Check className="h-3.5 w-3.5" />
                  </span>
                )}
              </div>
              <p className="mt-1 text-xs text-muted-foreground">{tier.description}</p>
            </button>
          );
        })}
      </div>

      {preference === "custom" && (
        <Card className="divide-y divide-border p-1">
          {CATEGORIES.map((cat) => (
            <div key={cat.key} className="flex items-center justify-between gap-4 px-4 py-3.5">
              <div className="min-w-0">
                <p className="text-sm font-semibold text-foreground">{cat.label}</p>
                <p className="text-xs text-muted-foreground">{cat.description}</p>
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
