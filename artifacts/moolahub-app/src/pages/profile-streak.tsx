import { useState } from "react";
import { Check, AlertCircle, Flame, Lock } from "lucide-react";
import { Badge } from "@/components/ui";
import { PageHeader, BackLink } from "@/components/app/bits";
import { useStreak, getGetStreaksQueryKey } from "@/hooks/use-streak";
import { useSetStreakFrequency } from "@workspace/api-client-react";
import { useQueryClient } from "@tanstack/react-query";
import { apiErrorMessage, cn } from "@/lib/utils";

type Frequency = "daily" | "weekly" | "monthly";

const OPTIONS: { key: Frequency; label: string; description: string; recommended?: boolean }[] = [
  {
    key: "daily",
    label: "Daily",
    description: "Keep the flame alive with a deposit every day. Best for an everyday saving habit.",
  },
  {
    key: "weekly",
    label: "Weekly",
    description: "One deposit any time during the week keeps your streak going. A calm, steady pace.",
    recommended: true,
  },
  {
    key: "monthly",
    label: "Monthly",
    description: "A single deposit each calendar month is all it takes. Gentle and low-pressure.",
  },
];

export default function ProfileStreakPage() {
  const { data, isLoading } = useStreak();
  const setFrequency = useSetStreakFrequency();
  const queryClient = useQueryClient();

  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  if (isLoading) return <div className="p-8 text-center text-muted-foreground">Loading…</div>;
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
      setError(apiErrorMessage(err) ?? "Could not change your streak frequency.");
    }
  };

  return (
    <div className="mx-auto max-w-2xl space-y-6">
      <BackLink href="/profile" label="Account" />
      <PageHeader
        eyebrow="Streaks"
        title="Streak frequency"
        description="Choose how often a deposit needs to happen to keep your savings streak alive."
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
        {OPTIONS.map((opt) => {
          const active = current === opt.key;
          return (
            <button
              key={opt.key}
              type="button"
              onClick={() => select(opt.key)}
              disabled={!canChange && !active}
              className={cn(
                "w-full rounded-2xl border bg-card p-4 text-left transition-colors focus-ring",
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
                  <span className="text-sm font-semibold text-foreground">{opt.label}</span>
                  {opt.recommended && <Badge tone="jade">Recommended</Badge>}
                </div>
                {active && (
                  <span className="flex h-5 w-5 items-center justify-center rounded-full bg-jade-500 text-white">
                    <Check className="h-3.5 w-3.5" />
                  </span>
                )}
              </div>
              <p className="mt-1 text-xs text-muted-foreground">{opt.description}</p>
            </button>
          );
        })}
      </div>

      {!canChange && (
        <div className="flex items-start gap-2 rounded-2xl border border-border bg-muted/40 p-4 text-sm text-muted-foreground">
          <Lock className="mt-0.5 h-4 w-4 shrink-0" />
          <p>
            You can change your streak frequency once per calendar year
            {data.nextChangeYear ? ` — your next change unlocks in ${data.nextChangeYear}.` : "."}
          </p>
        </div>
      )}
    </div>
  );
}
