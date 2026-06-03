export type Frequency = "daily" | "weekly" | "monthly";

const FREQUENCIES: Frequency[] = ["daily", "weekly", "monthly"];

export function asFrequency(value: string | null | undefined): Frequency {
  return FREQUENCIES.includes(value as Frequency) ? (value as Frequency) : "weekly";
}

/** Singular noun for "per X" phrasing, e.g. "$5/week". */
export const FREQUENCY_NOUN: Record<Frequency, string> = {
  daily: "day",
  weekly: "week",
  monthly: "month",
};

/** Short suffix for compact badges, e.g. "$5/wk". */
export const FREQUENCY_SHORT: Record<Frequency, string> = {
  daily: "day",
  weekly: "wk",
  monthly: "mo",
};

/** Adverb form, e.g. "Contribute weekly". */
export const FREQUENCY_ADVERB: Record<Frequency, string> = {
  daily: "daily",
  weekly: "weekly",
  monthly: "monthly",
};

export const FREQUENCY_OPTIONS: { value: Frequency; label: string }[] = [
  { value: "daily", label: "Daily" },
  { value: "weekly", label: "Weekly" },
  { value: "monthly", label: "Monthly" },
];

const MS_PER_DAY = 86_400_000;
const MAX_PERIODS = 520;

/** Number of contribution periods between two dates for a given frequency (min 1). */
export function periodsBetween(start: Date, end: Date, frequency: Frequency): number {
  const ms = end.getTime() - start.getTime();
  if (!Number.isFinite(ms) || ms <= 0) return 1;
  const days = ms / MS_PER_DAY;
  let n: number;
  if (frequency === "daily") {
    n = Math.round(days);
  } else if (frequency === "weekly") {
    n = Math.round(days / 7);
  } else {
    n =
      (end.getFullYear() - start.getFullYear()) * 12 +
      (end.getMonth() - start.getMonth());
  }
  return Math.max(1, Math.min(n, MAX_PERIODS));
}

/**
 * Progressive (escalating) contribution schedule. Amounts start small and grow
 * gradually so saving is easy at first and builds the habit, while still summing
 * exactly to `targetCents` across `periods` steps (the Susu savings-challenge model).
 */
export function progressivePlan(targetCents: number, periods: number): number[] {
  const target = Math.max(0, Math.round(targetCents));
  const n = Math.max(1, Math.floor(periods));
  if (n === 1) return [target];

  // Ideal step_i is proportional to i (linear ramp): step_i = target * 2i / (n(n+1)),
  // which sums exactly to `target`. Floor each step (keeps the sequence non-decreasing)
  // then hand the integer remainder to the largest steps (the suffix) so the schedule
  // stays non-decreasing AND sums to exactly `target` for every input, including tiny
  // targets where some early periods are skipped (amount 0).
  const denom = n * (n + 1);
  const plan: number[] = [];
  let allocated = 0;
  for (let i = 1; i <= n; i++) {
    const step = Math.floor((target * 2 * i) / denom);
    plan.push(step);
    allocated += step;
  }
  let remainder = target - allocated; // integer in [0, n)
  for (let i = n - 1; i >= 0 && remainder > 0; i--) {
    plan[i] += 1;
    remainder -= 1;
  }
  return plan;
}

export type NextContribution = {
  /** 1-based step number the saver is currently on. */
  index: number;
  /** Total number of steps in the plan. */
  total: number;
  /** Suggested amount for this step, in cents. */
  amountCents: number;
  /** Cumulative target once this step is completed, in cents. */
  cumulativeAfterCents: number;
};

/**
 * Given a schedule and how much is already saved, returns the next suggested
 * contribution (the first step whose cumulative total exceeds what's saved).
 * Returns null when the goal is fully funded.
 */
export function nextContribution(plan: number[], savedCents: number): NextContribution | null {
  let cumulative = 0;
  for (let i = 0; i < plan.length; i++) {
    cumulative += plan[i];
    if (savedCents < cumulative) {
      return {
        index: i + 1,
        total: plan.length,
        amountCents: plan[i],
        cumulativeAfterCents: cumulative,
      };
    }
  }
  return null;
}

export type GoalPlan = {
  frequency: Frequency;
  periods: number;
  plan: number[];
  firstCents: number;
  lastCents: number;
};

/** Build the full progressive plan for a goal from its target, dates and frequency. */
export function buildGoalPlan(
  targetCents: number,
  start: Date | string,
  deadline: Date | string,
  frequency: Frequency,
): GoalPlan {
  const startDate = typeof start === "string" ? new Date(start) : start;
  const endDate = typeof deadline === "string" ? new Date(deadline) : deadline;
  const periods = periodsBetween(startDate, endDate, frequency);
  const plan = progressivePlan(targetCents, periods);
  return {
    frequency,
    periods,
    plan,
    firstCents: plan.find((amt) => amt > 0) ?? plan[0] ?? 0,
    lastCents: plan[plan.length - 1] ?? 0,
  };
}
