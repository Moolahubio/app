import { Link } from "wouter";
import { useTranslation } from "react-i18next";
import { Flame, Snowflake, Plane, Sparkles } from "lucide-react";
import { cn } from "@/lib/utils";
import i18n from "@/i18n";

export type StreakStatus = "active" | "frozen" | "paused" | "broken" | string;

type Visual = {
  Icon: typeof Flame;
  color: string;
  glow: string;
  label: string;
};

/** Map a streak status + count to its flame visual. Hotter flames at longer runs. */
export function streakVisual(status: StreakStatus, count: number): Visual {
  if (status === "frozen") {
    return { Icon: Snowflake, color: "text-sky-500 dark:text-sky-400", glow: "bg-sky-500/15", label: i18n.t("streak:status.frozen") };
  }
  if (status === "paused") {
    return { Icon: Plane, color: "text-muted-foreground", glow: "bg-muted", label: i18n.t("streak:status.paused") };
  }
  if (status === "broken" || count === 0) {
    return { Icon: Flame, color: "text-muted-foreground", glow: "bg-muted", label: i18n.t("streak:status.broken") };
  }
  if (count >= 12) {
    return { Icon: Flame, color: "text-amber-500", glow: "bg-amber-500/15", label: i18n.t("streak:status.onFire") };
  }
  return { Icon: Flame, color: "text-jade-500", glow: "bg-jade-500/15", label: i18n.t("streak:status.active") };
}

const PERIOD_KEY: Record<string, string> = {
  daily: "day",
  monthly: "month",
  biweekly: "twoWeek",
  weekly: "week",
};

function periodKey(frequency: string): string {
  return PERIOD_KEY[frequency] ?? "week";
}

export function periodNoun(frequency: string): string {
  return i18n.t(`streak:period.${periodKey(frequency)}`);
}

/** Pluralized streak unit, e.g. 1 → "day", 3 → "weeks". */
export function streakUnit(frequency: string, count: number): string {
  return i18n.t(`streak:unit.${periodKey(frequency)}`, { count });
}

/** Small inline count + flame used on goal/circle detail and in lists. */
export function StreakChip({
  count,
  status,
  className,
}: {
  count: number;
  status: StreakStatus;
  className?: string;
}) {
  const v = streakVisual(status, count);
  return (
    <span className={cn("inline-flex items-center gap-1.5", className)}>
      <v.Icon className={cn("h-4 w-4", v.color)} />
      <span className="font-bold tabular-nums text-foreground">{count}</span>
    </span>
  );
}

/** Header pill that links to the streak screen — replaces the old "New goal" CTA. */
export function StreakIndicator({
  count,
  status,
  className,
}: {
  count: number;
  status: StreakStatus;
  className?: string;
}) {
  const { t } = useTranslation("streak");
  const v = streakVisual(status, count);
  return (
    <Link
      href="/streaks"
      aria-label={t("indicator.aria", { count })}
      className={cn(
        "flex items-center gap-2 rounded-xl border border-border bg-card px-3 py-1.5 transition-colors duration-150 hover:bg-muted active:bg-muted sm:px-4 sm:py-2",
        className,
      )}
    >
      <span className={cn("flex h-6 w-6 items-center justify-center rounded-full", v.glow)}>
        <v.Icon className={cn("h-4 w-4", v.color)} />
      </span>
      <span className="text-sm font-bold tabular-nums text-foreground">{count}</span>
    </Link>
  );
}

/** Big hero flame for the streak screen. */
export function StreakFlameHero({
  count,
  status,
  caption,
}: {
  count: number;
  status: StreakStatus;
  caption: string;
}) {
  const v = streakVisual(status, count);
  return (
    <div className="flex flex-col items-center text-center">
      <div className={cn("relative flex h-28 w-28 items-center justify-center rounded-full", v.glow)}>
        <v.Icon className={cn("h-14 w-14", v.color)} strokeWidth={1.5} />
        {count >= 4 && status === "active" && (
          <Sparkles className="absolute -end-1 top-1 h-5 w-5 text-amber-400" />
        )}
      </div>
      <p className="mt-4 font-display text-5xl font-bold tabular-nums text-foreground">{count}</p>
      <p className="mt-1 text-sm text-muted-foreground">{caption}</p>
    </div>
  );
}
