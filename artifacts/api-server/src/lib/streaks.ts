import { and, eq, isNull, lte, gt, ne, count } from "drizzle-orm";
import {
  db,
  streaksTable,
  streakPeriodsTable,
  streakFreezesTable,
  streakBadgesTable,
  usersTable,
  type Streak,
  type StreakFreeze,
  type User,
} from "@workspace/db";
import { notify } from "./notifications";
import { logger } from "./logger";
import { AppError } from "./errors";

/**
 * Savings Streaks engine — a derived, non-financial projection over real save
 * events. The double-entry ledger remains the source of truth for money; nothing
 * here moves or stores balances.
 *
 * The model is ONE streak per account: a single flame kept alive by ANY deposit
 * (a goal allocation OR a circle contribution) landing inside the current
 * calendar window. The window size is the user's chosen cadence — daily, weekly
 * (default) or monthly — aligned to the calendar in the user's timezone (weeks
 * start Monday). Per-goal/per-circle streaks are retired (legacy rows archived).
 *
 * Two write paths feed the engine:
 *  - recordSave(): called after a ledger commit in allocateToGoal()/contribute().
 *    Marks the current period satisfied and increments once per period. Idempotent.
 *  - evaluateStreaks(): scheduled job that rolls closed periods forward, applies
 *    freezes / vacation / breaks, awards calendar-time badges, grants freezes, and
 *    enqueues at most one reminder per period. Idempotent via streak_periods.
 */

export type Frequency = "daily" | "weekly" | "monthly";

/** Synthetic commitment type for the single per-user account streak. */
const ACCOUNT = "account";
const VALID_FREQ: readonly Frequency[] = ["daily", "weekly", "monthly"] as const;

const DAY_MS = 86_400_000;
const MAX_FREEZES = 4;
const ROLL_GUARD = 1200;

function normFreq(f: string | null | undefined): Frequency {
  return f === "daily" || f === "monthly" ? f : "weekly";
}

/** Lowercase cadence adjective, e.g. "weekly". */
function unitNoun(f: Frequency): string {
  return f;
}

/** Singular unit a count is measured in, e.g. weekly → "week". */
export function streakUnit(f: Frequency): string {
  return f === "daily" ? "day" : f === "monthly" ? "month" : "week";
}

function tierForOrder(order: number): "bronze" | "silver" | "gold" {
  if (order <= 3) return "bronze";
  if (order <= 7) return "silver";
  return "gold";
}

// --- Calendar-aligned period math (in the user's timezone) -----------------

const WEEKDAY_INDEX: Record<string, number> = {
  Mon: 0, Tue: 1, Wed: 2, Thu: 3, Fri: 4, Sat: 5, Sun: 6,
};

/** Local (tz) calendar parts of an instant; weekday 0=Mon..6=Sun. */
function tzParts(at: Date, tz: string): { y: number; m: number; d: number; weekday: number } {
  try {
    const parts = new Intl.DateTimeFormat("en-US", {
      timeZone: tz,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      weekday: "short",
    }).formatToParts(at);
    const map: Record<string, string> = {};
    for (const p of parts) map[p.type] = p.value;
    return {
      y: Number(map.year),
      m: Number(map.month),
      d: Number(map.day),
      weekday: WEEKDAY_INDEX[map.weekday] ?? 0,
    };
  } catch {
    return { y: at.getUTCFullYear(), m: at.getUTCMonth() + 1, d: at.getUTCDate(), weekday: (at.getUTCDay() + 6) % 7 };
  }
}

/** Milliseconds to add to a UTC instant to reach its local wall-clock value. */
function tzOffsetMs(at: Date, tz: string): number {
  try {
    const parts = new Intl.DateTimeFormat("en-US", {
      timeZone: tz,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    }).formatToParts(at);
    const map: Record<string, string> = {};
    for (const p of parts) map[p.type] = p.value;
    const asUTC = Date.UTC(
      Number(map.year),
      Number(map.month) - 1,
      Number(map.day),
      Number(map.hour),
      Number(map.minute),
      Number(map.second),
    );
    return asUTC - at.getTime();
  } catch {
    return 0;
  }
}

/** The UTC instant whose local (tz) wall-clock is exactly y-m-d 00:00:00. */
function zonedMidnightUTC(y: number, m: number, d: number, tz: string): Date {
  const guess = Date.UTC(y, m - 1, d, 0, 0, 0);
  const off1 = tzOffsetMs(new Date(guess), tz);
  let inst = guess - off1;
  const off2 = tzOffsetMs(new Date(inst), tz);
  if (off2 !== off1) inst = guess - off2;
  return new Date(inst);
}

/** Start of the calendar period containing `at`, for the cadence, in tz. */
function periodStartFor(at: Date, freq: Frequency, tz: string): Date {
  const { y, m, d, weekday } = tzParts(at, tz);
  if (freq === "daily") return zonedMidnightUTC(y, m, d, tz);
  if (freq === "monthly") return zonedMidnightUTC(y, m, 1, tz);
  // weekly: rewind to Monday of this local week.
  const monday = new Date(Date.UTC(y, m - 1, d) - weekday * DAY_MS);
  return zonedMidnightUTC(monday.getUTCFullYear(), monday.getUTCMonth() + 1, monday.getUTCDate(), tz);
}

/** Start of the calendar period immediately after the one beginning at `start`. */
function nextPeriodStart(start: Date, freq: Frequency, tz: string): Date {
  const { y, m, d } = tzParts(start, tz);
  if (freq === "monthly") {
    const ny = m === 12 ? y + 1 : y;
    const nm = m === 12 ? 1 : m + 1;
    return zonedMidnightUTC(ny, nm, 1, tz);
  }
  const step = freq === "daily" ? 1 : 7;
  const nxt = new Date(Date.UTC(y, m - 1, d) + step * DAY_MS);
  return zonedMidnightUTC(nxt.getUTCFullYear(), nxt.getUTCMonth() + 1, nxt.getUTCDate(), tz);
}

function addMonths(d: Date, n: number): Date {
  const r = new Date(d.getTime());
  const day = r.getUTCDate();
  r.setUTCDate(1);
  r.setUTCMonth(r.getUTCMonth() + n);
  // Clamp to the last valid day of the target month (anchor-day stability).
  const lastDay = new Date(Date.UTC(r.getUTCFullYear(), r.getUTCMonth() + 1, 0)).getUTCDate();
  r.setUTCDate(Math.min(day, lastDay));
  return r;
}

function monthsBetween(a: Date, b: Date): number {
  let n = (b.getUTCFullYear() - a.getUTCFullYear()) * 12 + (b.getUTCMonth() - a.getUTCMonth());
  if (b.getUTCDate() < a.getUTCDate()) n -= 1;
  return Math.max(0, n);
}

function intervalsOverlap(aStart: Date, aEnd: Date, bStart: Date | null, bEnd: Date | null): boolean {
  if (!bStart || !bEnd) return false;
  return aStart.getTime() < bEnd.getTime() && bStart.getTime() < aEnd.getTime();
}

function vacationOverlapMs(start: Date, now: Date, user: Pick<User, "vacationStart" | "vacationEnd">): number {
  if (!user.vacationStart || !user.vacationEnd) return 0;
  const s = Math.max(start.getTime(), user.vacationStart.getTime());
  const e = Math.min(now.getTime(), user.vacationEnd.getTime());
  return Math.max(0, e - s);
}

function localYear(at: Date, tz: string): number {
  try {
    const v = new Intl.DateTimeFormat("en-US", { timeZone: tz, year: "numeric" }).format(at);
    const n = Number(v);
    return Number.isFinite(n) ? n : at.getUTCFullYear();
  } catch {
    return at.getUTCFullYear();
  }
}

function localMonth(at: Date, tz: string): number {
  try {
    const v = new Intl.DateTimeFormat("en-US", { timeZone: tz, month: "numeric" }).format(at);
    const n = Number(v);
    return Number.isFinite(n) ? n : at.getUTCMonth() + 1;
  } catch {
    return at.getUTCMonth() + 1;
  }
}

function localQuarter(at: Date, tz: string): number {
  return Math.floor((localMonth(at, tz) - 1) / 3) + 1;
}

export function badgeKeyFor(year: number, quarterIndex: number): string {
  return `${year}-q${quarterIndex}`;
}

type Tx = Parameters<Parameters<typeof db.transaction>[0]>[0];

async function ensureFreezeRow(tx: Tx, userId: string): Promise<StreakFreeze> {
  const [existing] = await tx
    .select()
    .from(streakFreezesTable)
    .where(eq(streakFreezesTable.userId, userId))
    .for("update");
  if (existing) return existing;
  const [created] = await tx
    .insert(streakFreezesTable)
    .values({ userId })
    .onConflictDoNothing({ target: streakFreezesTable.userId })
    .returning();
  if (created) return created;
  const [row] = await tx
    .select()
    .from(streakFreezesTable)
    .where(eq(streakFreezesTable.userId, userId))
    .for("update");
  return row!;
}

/**
 * Roll any closed periods forward in place, applying: vacation pause → satisfied
 * roll-forward → freeze → break. Mutates `s` and `freeze` and appends period
 * outcome rows (idempotent). Does not persist; the caller writes the result.
 */
async function rollForward(
  tx: Tx,
  s: Streak,
  user: Pick<User, "vacationStart" | "vacationEnd">,
  freeze: StreakFreeze,
  freq: Frequency,
  tz: string,
  now: Date,
): Promise<{ streakChanged: boolean; freezeChanged: boolean }> {
  if (s.currentPeriodEnd.getTime() > now.getTime()) return { streakChanged: false, freezeChanged: false };

  let freezeChanged = false;
  let guard = 0;
  let pStart = s.currentPeriodStart;
  let pEnd = s.currentPeriodEnd;
  let satisfied = s.currentPeriodSatisfied;

  // Walk each closed calendar period to `now`, applying the outcome ladder:
  // vacation pause → satisfied roll-forward → freeze → break.
  while (pEnd.getTime() <= now.getTime() && guard < ROLL_GUARD) {
    guard++;
    const onVacation = intervalsOverlap(pStart, pEnd, user.vacationStart, user.vacationEnd);
    let outcome: "saved" | "frozen" | "paused" | "missed";

    if (onVacation) {
      outcome = "paused";
      s.status = "paused";
    } else if (satisfied) {
      outcome = "saved";
      s.status = "active";
    } else if (s.status === "broken" || s.currentCount === 0) {
      outcome = "missed";
      s.status = "broken";
    } else {
      const canFreeze =
        freeze.balance > 0 &&
        (!freeze.lastUsedAt || pEnd.getTime() >= addMonths(freeze.lastUsedAt, 3).getTime());
      if (canFreeze) {
        freeze.balance -= 1;
        freeze.usedTotal += 1;
        freeze.lastUsedAt = pEnd;
        freezeChanged = true;
        outcome = "frozen";
        s.status = "frozen";
      } else {
        if (s.currentCount > s.bestCount) s.bestCount = s.currentCount;
        s.currentCount = 0;
        s.status = "broken";
        outcome = "missed";
      }
    }

    await tx
      .insert(streakPeriodsTable)
      .values({
        streakId: s.id,
        periodStart: pStart,
        periodEnd: pEnd,
        outcome,
        saveCount: outcome === "saved" ? 1 : 0,
      })
      .onConflictDoNothing({ target: [streakPeriodsTable.streakId, streakPeriodsTable.periodStart] });

    satisfied = false;
    pStart = pEnd;
    pEnd = nextPeriodStart(pEnd, freq, tz);
  }

  // Re-anchor the current period to the calendar period containing `now`.
  const curStart = periodStartFor(now, freq, tz);
  const curEnd = nextPeriodStart(curStart, freq, tz);
  s.currentPeriodStart = curStart;
  s.currentPeriodEnd = curEnd;
  s.currentPeriodSatisfied = false;
  if (s.status !== "broken" && !intervalsOverlap(curStart, curEnd, user.vacationStart, user.vacationEnd)) {
    if (s.status === "paused") s.status = "active";
  }
  return { streakChanged: true, freezeChanged };
}

/** Award every calendar-time badge the streak has earned (idempotent). */
async function awardBadges(
  tx: Tx,
  s: Streak,
  user: Pick<User, "timezone" | "vacationStart" | "vacationEnd">,
  now: Date,
): Promise<void> {
  if (s.status === "broken" || s.currentCount === 0) return;
  const tz = user.timezone || "UTC";
  const vacMs = vacationOverlapMs(s.startedAt, now, user);
  const effectiveNow = new Date(now.getTime() - vacMs);
  const milestones = Math.floor(monthsBetween(s.startedAt, effectiveNow) / 3);
  for (let q = 1; q <= milestones; q++) {
    const at = addMonths(s.startedAt, q * 3);
    const year = localYear(at, tz);
    const quarterIndex = localQuarter(at, tz);
    await tx
      .insert(streakBadgesTable)
      .values({
        userId: s.userId,
        badgeKey: badgeKeyFor(year, quarterIndex),
        year,
        quarterIndex,
        sourceCommitmentId: s.commitmentId,
      })
      .onConflictDoNothing({
        target: [streakBadgesTable.userId, streakBadgesTable.year, streakBadgesTable.quarterIndex],
      });
  }
}

async function persistStreak(tx: Tx, s: Streak): Promise<void> {
  await tx
    .update(streaksTable)
    .set({
      currentCount: s.currentCount,
      bestCount: s.bestCount,
      status: s.status,
      currentPeriodStart: s.currentPeriodStart,
      currentPeriodEnd: s.currentPeriodEnd,
      currentPeriodSatisfied: s.currentPeriodSatisfied,
      lastSaveRef: s.lastSaveRef,
      startedAt: s.startedAt,
    })
    .where(eq(streaksTable.id, s.id));
}

async function persistFreeze(tx: Tx, f: StreakFreeze): Promise<void> {
  await tx
    .update(streakFreezesTable)
    .set({
      balance: f.balance,
      lastGrantedAt: f.lastGrantedAt,
      lastUsedAt: f.lastUsedAt,
      grantedTotal: f.grantedTotal,
      usedTotal: f.usedTotal,
      grantYear: f.grantYear,
      grantsThisYear: f.grantsThisYear,
    })
    .where(eq(streakFreezesTable.id, f.id));
}

/**
 * Mark the current period satisfied for the user's single ACCOUNT streak,
 * creating it on the first save. Any deposit qualifies — a goal allocation or a
 * circle contribution. Increments once per calendar period; idempotent for
 * repeat saves in the same period (and for replays of the same saveRef). Call
 * AFTER the ledger commit. Never throws.
 */
export async function recordSave(
  userId: string,
  saveRef: string,
  at: Date = new Date(),
): Promise<void> {
  try {
    await db.transaction(async (tx) => {
      const [user] = await tx
        .select({
          streakFrequency: usersTable.streakFrequency,
          timezone: usersTable.timezone,
          vacationStart: usersTable.vacationStart,
          vacationEnd: usersTable.vacationEnd,
        })
        .from(usersTable)
        .where(eq(usersTable.id, userId));
      const freq = normFreq(user?.streakFrequency);
      const tz = user?.timezone || "UTC";
      const vac = { vacationStart: user?.vacationStart ?? null, vacationEnd: user?.vacationEnd ?? null };

      const [existing] = await tx
        .select()
        .from(streaksTable)
        .where(
          and(
            eq(streaksTable.userId, userId),
            eq(streaksTable.commitmentType, ACCOUNT),
            eq(streaksTable.commitmentId, userId),
          ),
        )
        .for("update");

      if (!existing) {
        const start = periodStartFor(at, freq, tz);
        const end = nextPeriodStart(start, freq, tz);
        await tx
          .insert(streaksTable)
          .values({
            userId,
            commitmentType: ACCOUNT,
            commitmentId: userId,
            frequency: freq,
            startedAt: at,
            currentCount: 1,
            bestCount: 1,
            status: "active",
            currentPeriodStart: start,
            currentPeriodEnd: end,
            currentPeriodSatisfied: true,
            lastSaveRef: saveRef,
          })
          .onConflictDoNothing({
            target: [streaksTable.userId, streaksTable.commitmentType, streaksTable.commitmentId],
          });
        return;
      }

      // Idempotent: replaying the exact same save reference must not advance.
      if (existing.lastSaveRef && existing.lastSaveRef === saveRef) return;

      const s: Streak = { ...existing, frequency: freq };
      const freeze = await ensureFreezeRow(tx, userId);

      const { freezeChanged } = await rollForward(tx, s, vac, freeze, freq, tz, at);

      // Apply the save to the now-current period.
      if (s.status === "broken" || s.currentCount === 0) {
        // Revive: a fresh streak starts here, re-anchored to this save.
        const start = periodStartFor(at, freq, tz);
        const end = nextPeriodStart(start, freq, tz);
        s.startedAt = at;
        s.currentPeriodStart = start;
        s.currentPeriodEnd = end;
        s.currentCount = 1;
        s.status = "active";
        s.currentPeriodSatisfied = true;
        if (s.bestCount < 1) s.bestCount = 1;
      } else if (!s.currentPeriodSatisfied) {
        s.currentCount += 1;
        s.currentPeriodSatisfied = true;
        s.status = "active";
        if (s.currentCount > s.bestCount) s.bestCount = s.currentCount;
      }
      s.lastSaveRef = saveRef;

      await persistStreak(tx, s);
      if (freezeChanged) await persistFreeze(tx, freeze);
    });
  } catch (e) {
    logger.error({ err: e, userId }, "[streaks] recordSave failed");
  }
}

/** Grant freezes (1 per 3 months, cap 4/year, balance cap 4) to active savers. */
async function grantFreezes(now: Date): Promise<void> {
  const users = await db
    .select({ id: usersTable.id, timezone: usersTable.timezone })
    .from(usersTable)
    .innerJoin(streaksTable, eq(streaksTable.userId, usersTable.id))
    .where(and(isNull(streaksTable.archivedAt), ne(streaksTable.status, "broken")))
    .groupBy(usersTable.id, usersTable.timezone);

  for (const u of users) {
    try {
      await db.transaction(async (tx) => {
        const f = await ensureFreezeRow(tx, u.id);
        const tz = u.timezone || "UTC";
        const year = localYear(now, tz);
        if (f.grantYear !== year) {
          f.grantYear = year;
          f.grantsThisYear = 0;
        }
        const due = !f.lastGrantedAt || now.getTime() >= addMonths(f.lastGrantedAt, 3).getTime();
        if (due && f.grantsThisYear < MAX_FREEZES && f.balance < MAX_FREEZES) {
          f.balance += 1;
          f.grantsThisYear += 1;
          f.grantedTotal += 1;
          f.lastGrantedAt = now;
          await persistFreeze(tx, f);
        } else if (f.grantYear === year && f.grantsThisYear === 0) {
          // Persist the year reset even when no grant is due.
          await persistFreeze(tx, f);
        }
      });
    } catch (e) {
      logger.error({ err: e, userId: u.id }, "[streaks] grantFreezes failed");
    }
  }
}

/** Send at most one pre-close reminder per (streak, period) to opted-in users. */
async function sendReminders(now: Date): Promise<void> {
  const rows = await db
    .select({
      streak: streaksTable,
      frequency: usersTable.streakFrequency,
    })
    .from(streaksTable)
    .innerJoin(usersTable, eq(usersTable.id, streaksTable.userId))
    .where(
      and(
        eq(usersTable.streakReminderOptIn, true),
        isNull(streaksTable.archivedAt),
        eq(streaksTable.currentPeriodSatisfied, false),
        ne(streaksTable.status, "broken"),
        ne(streaksTable.status, "paused"),
        gt(streaksTable.currentPeriodEnd, now),
      ),
    );

  for (const { streak: s, frequency } of rows) {
    try {
      // Only nudge in the closing window: within the last 40% of the period and
      // no more than 3 days before close — and never twice for the same period.
      const total = s.currentPeriodEnd.getTime() - s.currentPeriodStart.getTime();
      const remaining = s.currentPeriodEnd.getTime() - now.getTime();
      const inWindow = remaining <= Math.min(total * 0.4, 3 * DAY_MS);
      const alreadySent =
        s.reminderSentPeriodStart &&
        s.reminderSentPeriodStart.getTime() === s.currentPeriodStart.getTime();
      if (!inWindow || alreadySent) continue;

      const freq = normFreq(frequency);
      const daysLeft = Math.max(0, Math.ceil(remaining / DAY_MS));
      const when = freq === "daily" ? "today" : daysLeft <= 1 ? "tomorrow" : `in ${daysLeft} days`;
      await notify(s.userId, {
        type: "streak_reminder",
        title: "Keep your streak going",
        body: `Your ${unitNoun(freq)} streak window closes ${when}. A small save to any goal or circle keeps your flame alive — no rush.`,
        link: "/streaks",
      });
      await db
        .update(streaksTable)
        .set({ reminderSentPeriodStart: s.currentPeriodStart })
        .where(eq(streaksTable.id, s.id));
    } catch (e) {
      logger.error({ err: e, streakId: s.id }, "[streaks] reminder failed");
    }
  }
}

/** Daily job: grant freezes, roll closed periods, award badges, send reminders. */
export async function evaluateStreaks(now: Date = new Date()): Promise<void> {
  await grantFreezes(now);

  const due = await db
    .select({ id: streaksTable.id, userId: streaksTable.userId })
    .from(streaksTable)
    .where(and(isNull(streaksTable.archivedAt), lte(streaksTable.currentPeriodEnd, now)));

  for (const row of due) {
    try {
      await db.transaction(async (tx) => {
        const [locked] = await tx
          .select()
          .from(streaksTable)
          .where(eq(streaksTable.id, row.id))
          .for("update");
        if (!locked || locked.archivedAt) return;
        if (locked.currentPeriodEnd.getTime() > now.getTime()) return;

        const [user] = await tx
          .select({
            timezone: usersTable.timezone,
            streakFrequency: usersTable.streakFrequency,
            vacationStart: usersTable.vacationStart,
            vacationEnd: usersTable.vacationEnd,
          })
          .from(usersTable)
          .where(eq(usersTable.id, locked.userId));
        const u = user ?? { timezone: "UTC", streakFrequency: "weekly", vacationStart: null, vacationEnd: null };
        const tz = u.timezone || "UTC";
        const freq = normFreq(u.streakFrequency);
        const freeze = await ensureFreezeRow(tx, locked.userId);

        const s: Streak = { ...locked };
        const { freezeChanged } = await rollForward(tx, s, u, freeze, freq, tz, now);
        await awardBadges(tx, s, u, now);
        await persistStreak(tx, s);
        if (freezeChanged) await persistFreeze(tx, freeze);
      });
    } catch (e) {
      logger.error({ err: e, streakId: row.id }, "[streaks] evaluate failed");
    }
  }

  await sendReminders(now);
}

let streakTimer: ReturnType<typeof setInterval> | null = null;
const STREAK_INTERVAL_MS = 6 * 60 * 60 * 1000; // every 6h; idempotent so frequency is safe

/** Start the periodic streak evaluator and run once on boot to recover. */
export async function startStreakLoop(): Promise<void> {
  if (streakTimer) return;
  try {
    await evaluateStreaks();
  } catch (e) {
    logger.error({ err: e }, "[streaks] boot evaluate failed");
  }
  streakTimer = setInterval(() => {
    void evaluateStreaks();
  }, STREAK_INTERVAL_MS);
  streakTimer.unref?.();
}

// ---------------------------------------------------------------------------
// Read/Write API used by routes/streaks.ts
// ---------------------------------------------------------------------------

const ALIVE_STATUSES = ["active", "frozen", "paused"] as const;

/**
 * Legacy per-commitment streak view. Per-goal/per-circle streaks are retired, so
 * the API now always returns an empty `commitments` list; the type is kept for
 * response-shape compatibility.
 */
export type StreakCommitmentView = {
  id: string;
  commitmentType: string;
  commitmentId: string;
  commitmentName: string;
  emoji: string | null;
  frequency: string;
  currentCount: number;
  bestCount: number;
  status: string;
  currentPeriodEnd: string;
  currentPeriodSatisfied: boolean;
};

export type StreakBadgeView = {
  badgeKey: string;
  year: number;
  quarterIndex: number;
  earnedAt: string;
};

export type StreakBadgeProgress = {
  earnedQuarters: number;
  nextTier: "bronze" | "silver" | "gold";
  pct: number;
  daysToNext: number | null;
};

export type StreakOverview = {
  hero: {
    count: number;
    status: string;
    commitmentName: string | null;
    emoji: string | null;
  } | null;
  frequency: Frequency;
  canChangeFrequency: boolean;
  nextChangeYear: number | null;
  currentPeriodEnd: string | null;
  currentPeriodSatisfied: boolean;
  atRisk: boolean;
  lifetimeBest: number;
  totalPeriodsSaved: number;
  commitments: StreakCommitmentView[];
  freezes: { balance: number; usedTotal: number };
  badges: StreakBadgeView[];
  badgeProgress: StreakBadgeProgress;
  reminderOptIn: boolean;
  vacation: { active: boolean; start: string | null; end: string | null; usedThisYear: boolean };
};

/**
 * Progress toward the next quarterly badge, derived from how long the current
 * unbroken streak has run (vacation time excluded). A broken/empty streak shows
 * no progress.
 */
function computeBadgeProgress(
  s: Streak | undefined,
  user: Pick<User, "vacationStart" | "vacationEnd">,
  earnedCount: number,
  now: Date,
): StreakBadgeProgress {
  if (!s || s.status === "broken" || s.currentCount === 0) {
    return { earnedQuarters: earnedCount, nextTier: tierForOrder(earnedCount + 1), pct: 0, daysToNext: null };
  }
  const vacMs = vacationOverlapMs(s.startedAt, now, user);
  const effNow = new Date(now.getTime() - vacMs);
  const earnedQuarters = Math.floor(monthsBetween(s.startedAt, effNow) / 3);
  const quarterStart = addMonths(s.startedAt, earnedQuarters * 3);
  const quarterEnd = addMonths(s.startedAt, (earnedQuarters + 1) * 3);
  const span = quarterEnd.getTime() - quarterStart.getTime();
  const elapsed = Math.max(0, effNow.getTime() - quarterStart.getTime());
  const pct = span > 0 ? Math.max(0, Math.min(1, elapsed / span)) : 0;
  const daysToNext = Math.max(0, Math.ceil((quarterEnd.getTime() - effNow.getTime()) / DAY_MS));
  return { earnedQuarters, nextTier: tierForOrder(earnedQuarters + 1), pct, daysToNext };
}

export async function getStreakOverview(userId: string): Promise<StreakOverview> {
  const [user] = await db
    .select({
      timezone: usersTable.timezone,
      streakReminderOptIn: usersTable.streakReminderOptIn,
      streakFrequency: usersTable.streakFrequency,
      streakFrequencyLastChanged: usersTable.streakFrequencyLastChanged,
      vacationStart: usersTable.vacationStart,
      vacationEnd: usersTable.vacationEnd,
      vacationYearUsed: usersTable.vacationYearUsed,
    })
    .from(usersTable)
    .where(eq(usersTable.id, userId));

  const [s] = await db
    .select()
    .from(streaksTable)
    .where(
      and(
        eq(streaksTable.userId, userId),
        eq(streaksTable.commitmentType, ACCOUNT),
        eq(streaksTable.commitmentId, userId),
        isNull(streaksTable.archivedAt),
      ),
    );

  const tz = user?.timezone || "UTC";
  const now = new Date();
  const freq = normFreq(user?.streakFrequency);
  const vac = { vacationStart: user?.vacationStart ?? null, vacationEnd: user?.vacationEnd ?? null };

  const alive = Boolean(s && (ALIVE_STATUSES as readonly string[]).includes(s.status));
  const hero = s && alive ? { count: s.currentCount, status: s.status, commitmentName: null, emoji: null } : null;
  const lifetimeBest = s ? Math.max(s.bestCount, s.currentCount) : 0;

  let totalPeriodsSaved = 0;
  if (s) {
    const [agg] = await db
      .select({ saved: count() })
      .from(streakPeriodsTable)
      .where(and(eq(streakPeriodsTable.streakId, s.id), eq(streakPeriodsTable.outcome, "saved")));
    totalPeriodsSaved = Number(agg?.saved ?? 0);
    // Include the currently-satisfied (open) period, which isn't logged yet.
    if (s.currentPeriodSatisfied) totalPeriodsSaved += 1;
  }

  const [freeze] = await db
    .select({ balance: streakFreezesTable.balance, usedTotal: streakFreezesTable.usedTotal })
    .from(streakFreezesTable)
    .where(eq(streakFreezesTable.userId, userId));

  const badgeRows = await db
    .select({
      badgeKey: streakBadgesTable.badgeKey,
      year: streakBadgesTable.year,
      quarterIndex: streakBadgesTable.quarterIndex,
      earnedAt: streakBadgesTable.earnedAt,
    })
    .from(streakBadgesTable)
    .where(eq(streakBadgesTable.userId, userId))
    .orderBy(streakBadgesTable.year, streakBadgesTable.quarterIndex);

  const vacActive = Boolean(
    user?.vacationStart && user?.vacationEnd &&
      user.vacationStart.getTime() <= now.getTime() &&
      now.getTime() < user.vacationEnd.getTime(),
  );

  const changedThisYear = Boolean(
    user?.streakFrequencyLastChanged &&
      localYear(user.streakFrequencyLastChanged, tz) === localYear(now, tz),
  );
  const nextChangeYear =
    changedThisYear && user?.streakFrequencyLastChanged
      ? localYear(user.streakFrequencyLastChanged, tz) + 1
      : null;

  // "At risk" = an alive, non-paused streak whose current window is still open
  // but not yet satisfied. Used for a gentle (never alarming) banner.
  const atRisk = Boolean(
    s && alive && s.status !== "paused" && s.currentCount > 0 &&
      !s.currentPeriodSatisfied && s.currentPeriodEnd.getTime() > now.getTime(),
  );

  return {
    hero,
    frequency: freq,
    canChangeFrequency: !changedThisYear,
    nextChangeYear,
    currentPeriodEnd: s ? s.currentPeriodEnd.toISOString() : null,
    currentPeriodSatisfied: s ? s.currentPeriodSatisfied : false,
    atRisk,
    lifetimeBest,
    totalPeriodsSaved,
    commitments: [],
    freezes: { balance: freeze?.balance ?? 0, usedTotal: freeze?.usedTotal ?? 0 },
    badges: badgeRows.map((b) => ({
      badgeKey: b.badgeKey,
      year: b.year,
      quarterIndex: b.quarterIndex,
      earnedAt: b.earnedAt.toISOString(),
    })),
    badgeProgress: computeBadgeProgress(s, vac, badgeRows.length, now),
    reminderOptIn: user?.streakReminderOptIn ?? false,
    vacation: {
      active: vacActive,
      start: user?.vacationStart?.toISOString() ?? null,
      end: user?.vacationEnd?.toISOString() ?? null,
      usedThisYear: user?.vacationYearUsed === localYear(now, tz),
    },
  };
}

/**
 * Change the account-streak cadence. Allowed once per calendar year (no-op when
 * unchanged). Re-anchors the streak to a fresh window of the new cadence while
 * keeping the current count — switching cadence never punishes existing progress.
 */
export async function setStreakFrequency(userId: string, frequency: string): Promise<StreakOverview> {
  if (!VALID_FREQ.includes(frequency as Frequency)) {
    throw new AppError("Choose a daily, weekly, or monthly streak.");
  }
  const next = frequency as Frequency;
  const now = new Date();
  const [user] = await db
    .select({
      timezone: usersTable.timezone,
      streakFrequency: usersTable.streakFrequency,
      streakFrequencyLastChanged: usersTable.streakFrequencyLastChanged,
    })
    .from(usersTable)
    .where(eq(usersTable.id, userId));
  const tz = user?.timezone || "UTC";
  const current = normFreq(user?.streakFrequency);
  if (next === current) {
    // No-op — don't consume the annual change allowance.
    return getStreakOverview(userId);
  }
  if (
    user?.streakFrequencyLastChanged &&
    localYear(user.streakFrequencyLastChanged, tz) === localYear(now, tz)
  ) {
    throw new AppError("You can change your streak frequency once per calendar year.");
  }

  await db.transaction(async (tx) => {
    await tx
      .update(usersTable)
      .set({ streakFrequency: next, streakFrequencyLastChanged: now })
      .where(eq(usersTable.id, userId));
    const [s] = await tx
      .select()
      .from(streaksTable)
      .where(
        and(
          eq(streaksTable.userId, userId),
          eq(streaksTable.commitmentType, ACCOUNT),
          eq(streaksTable.commitmentId, userId),
        ),
      )
      .for("update");
    if (s) {
      const start = periodStartFor(now, next, tz);
      const end = nextPeriodStart(start, next, tz);
      await tx
        .update(streaksTable)
        .set({
          frequency: next,
          currentPeriodStart: start,
          currentPeriodEnd: end,
          currentPeriodSatisfied: false,
          reminderSentPeriodStart: null,
          status: s.status === "broken" ? "broken" : s.status === "paused" ? "paused" : "active",
        })
        .where(eq(streaksTable.id, s.id));
    }
  });

  return getStreakOverview(userId);
}

export async function setReminderOptIn(userId: string, optIn: boolean): Promise<{ optIn: boolean }> {
  await db.update(usersTable).set({ streakReminderOptIn: optIn }).where(eq(usersTable.id, userId));
  return { optIn };
}

/** Start the single annual vacation (<=30 days, once per calendar year). */
export async function startVacation(userId: string, days: number): Promise<StreakOverview> {
  if (!Number.isFinite(days) || days < 1 || days > 30) {
    throw new AppError("Vacation must be between 1 and 30 days");
  }
  const now = new Date();
  const [user] = await db
    .select({ timezone: usersTable.timezone, vacationYearUsed: usersTable.vacationYearUsed })
    .from(usersTable)
    .where(eq(usersTable.id, userId));
  const tz = user?.timezone || "UTC";
  const year = localYear(now, tz);
  if (user?.vacationYearUsed === year) {
    throw new AppError("You've already used your vacation this year");
  }
  const end = new Date(now.getTime() + Math.round(days) * DAY_MS);
  await db
    .update(usersTable)
    .set({ vacationStart: now, vacationEnd: end, vacationYearUsed: year })
    .where(eq(usersTable.id, userId));
  // Pause alive streaks immediately for a responsive UI; the job keeps them paused.
  await db
    .update(streaksTable)
    .set({ status: "paused" })
    .where(
      and(
        eq(streaksTable.userId, userId),
        isNull(streaksTable.archivedAt),
        ne(streaksTable.status, "broken"),
      ),
    );
  return getStreakOverview(userId);
}

/** End the vacation early (forfeits the rest; the annual allowance stays spent). */
export async function endVacation(userId: string): Promise<StreakOverview> {
  const now = new Date();
  await db
    .update(usersTable)
    .set({ vacationEnd: now })
    .where(and(eq(usersTable.id, userId), gt(usersTable.vacationEnd, now)));
  await db
    .update(streaksTable)
    .set({ status: "active" })
    .where(
      and(
        eq(streaksTable.userId, userId),
        isNull(streaksTable.archivedAt),
        eq(streaksTable.status, "paused"),
      ),
    );
  return getStreakOverview(userId);
}
