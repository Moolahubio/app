import type { StreakBadge } from "@workspace/api-client-react";
import { Medal } from "lucide-react";
import { cn } from "@/lib/utils";

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
