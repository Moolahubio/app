import type { StreakBadge, StreakBadgeProgress } from "@workspace/api-client-react";
import { Medal } from "lucide-react";
import { cn } from "@/lib/utils";

type Tier = "bronze" | "silver" | "gold";

const TIER_META: Record<Tier, { label: string; ring: string; text: string; chip: string }> = {
  bronze: {
    label: "Bronze",
    ring: "ring-amber-700/30",
    text: "text-amber-700 dark:text-amber-500",
    chip: "bg-amber-700/15",
  },
  silver: {
    label: "Silver",
    ring: "ring-slate-400/30",
    text: "text-slate-500 dark:text-slate-300",
    chip: "bg-slate-400/15",
  },
  gold: {
    label: "Gold",
    ring: "ring-amber-400/40",
    text: "text-amber-500 dark:text-amber-400",
    chip: "bg-amber-400/15",
  },
};

/** Tier earned for a given number of completed quarters: Bronze 1–3, Silver 4–7, Gold 8+. */
export function tierForCount(quarters: number): Tier | null {
  if (quarters >= 8) return "gold";
  if (quarters >= 4) return "silver";
  if (quarters >= 1) return "bronze";
  return null;
}

/**
 * Current rank + a calm progress bar toward the next quarterly badge. Shows the
 * tier the user has reached and how far into the current quarter they are.
 */
export function StreakBadgeTier({ progress }: { progress: StreakBadgeProgress }) {
  const current = tierForCount(progress.earnedQuarters);
  const nextMeta = TIER_META[progress.nextTier as Tier];
  const pct = Math.round(Math.max(0, Math.min(1, progress.pct)) * 100);

  return (
    <div className="rounded-2xl border border-border bg-card p-5">
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-3">
          <span
            className={cn(
              "flex h-11 w-11 items-center justify-center rounded-2xl ring-1 ring-inset",
              current ? `${TIER_META[current].chip} ${TIER_META[current].ring}` : "bg-muted ring-transparent",
            )}
          >
            <Medal className={cn("h-6 w-6", current ? TIER_META[current].text : "text-muted-foreground/50")} />
          </span>
          <div>
            <p className="text-sm font-semibold text-foreground">
              {current ? `${TIER_META[current].label} saver` : "No badge yet"}
            </p>
            <p className="text-xs text-muted-foreground">
              {progress.earnedQuarters} {progress.earnedQuarters === 1 ? "quarter" : "quarters"} kept
            </p>
          </div>
        </div>
        <span className={cn("rounded-full px-2.5 py-1 text-[11px] font-semibold", nextMeta.chip, nextMeta.text)}>
          Next: {nextMeta.label}
        </span>
      </div>

      <div className="mt-4">
        <div className="h-2 overflow-hidden rounded-full bg-muted">
          <div
            className="h-full rounded-full bg-jade-500 transition-[width] duration-500"
            style={{ width: `${pct}%` }}
          />
        </div>
        <p className="mt-2 text-xs text-muted-foreground">
          {progress.daysToNext == null
            ? "Keep your streak alive for three months to earn your next badge."
            : progress.daysToNext === 0
              ? "Your next badge lands today, keep it going."
              : `${progress.daysToNext} ${progress.daysToNext === 1 ? "day" : "days"} to your next badge.`}
        </p>
      </div>
    </div>
  );
}

const QUARTER_TONE: Record<number, string> = {
  1: "bg-sky-500/15 text-sky-600 dark:text-sky-300 ring-sky-500/25",
  2: "bg-jade-500/15 text-jade-600 dark:text-jade-300 ring-jade-500/25",
  3: "bg-amber-500/15 text-amber-600 dark:text-amber-300 ring-amber-500/25",
  4: "bg-violet-500/15 text-violet-600 dark:text-violet-300 ring-violet-500/25",
};

const QUARTER_NAME: Record<number, string> = { 1: "Winter", 2: "Spring", 3: "Summer", 4: "Autumn" };

/** Collectible badge grid — one slot per calendar quarter, unique per year. */
export function StreakBadges({ badges }: { badges: StreakBadge[] }) {
  if (badges.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        Keep a streak alive for three months to earn your first badge. There are four to collect each
        year, one for every season.
      </p>
    );
  }

  const byYear = new Map<number, StreakBadge[]>();
  for (const b of badges) {
    const list = byYear.get(b.year) ?? [];
    list.push(b);
    byYear.set(b.year, list);
  }
  const years = [...byYear.keys()].sort((a, b) => b - a);

  return (
    <div className="space-y-5">
      {years.map((year) => (
        <div key={year}>
          <p className="mb-2 font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
            {year}
          </p>
          <div className="grid grid-cols-4 gap-3">
            {[1, 2, 3, 4].map((q) => {
              const earned = byYear.get(year)!.some((b) => b.quarterIndex === q);
              return (
                <div
                  key={q}
                  className={cn(
                    "flex flex-col items-center gap-1.5 rounded-2xl border p-3 text-center ring-1 ring-inset",
                    earned
                      ? QUARTER_TONE[q]
                      : "border-dashed border-border bg-card text-muted-foreground ring-transparent",
                  )}
                >
                  <Medal className={cn("h-7 w-7", earned ? "" : "opacity-40")} />
                  <span className="text-[11px] font-semibold">Q{q}</span>
                  <span className="text-[10px] text-muted-foreground">{QUARTER_NAME[q]}</span>
                </div>
              );
            })}
          </div>
        </div>
      ))}
    </div>
  );
}
