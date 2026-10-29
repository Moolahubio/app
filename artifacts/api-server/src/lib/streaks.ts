import { and, eq, isNull, lte, gt, gte, ne, count, desc } from "drizzle-orm";
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
const HOUR_MS = 3_600_000;
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

/**
 * The UTC instant whose local (tz) wall-clock is exactly y-m-d 00:00:00. When a
 * DST jump skips local midnight, the first instant of that local date: the day
 * starts right after the jump.
 */
function zonedMidnightUTC(y: number, m: number, d: number, tz: string): Date {
  const guess = Date.UTC(y, m - 1, d, 0, 0, 0);
  const off1 = tzOffsetMs(new Date(guess), tz);
  let inst = guess - off1;
  const off2 = tzOffsetMs(new Date(inst), tz);
  if (off2 !== off1) inst = guess - off2;
  if (tzParts(new Date(inst), tz).d !== d) inst = Math.max(guess - off1, guess - off2);
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

/**
 * End of the period beginning at `start`: the next period start, guarded so no
 * period is ever zero-length (logged, never thrown).
 */
function periodEndFor(start: Date, freq: Frequency, tz: string): Date {
  const end = nextPeriodStart(start, freq, tz);
  if (end.getTime() > start.getTime()) return end;
  logger.warn({ start, freq, tz }, "[streaks] period end is not after its start");
  return nextPeriodStart(new Date(start.getTime() + 12 * HOUR_MS), freq, tz);
}

/**
 * Local midnight `n` months after the local date of `at` in tz, the day clamped
 * to the last of the target month.
 */
function localMonthsLater(at: Date, n: number, tz: string): Date {
  const { y, m, d } = tzParts(at, tz);
  const t = new Date(Date.UTC(y, m - 1 + n, 1));
  const last = new Date(Date.UTC(t.getUTCFullYear(), t.getUTCMonth() + 1, 0)).getUTCDate();
  return zonedMidnightUTC(t.getUTCFullYear(), t.getUTCMonth() + 1, Math.min(d, last), tz);
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
      // The 3-month cooldown runs on the local calendar, not on instants or UTC
      // dates: the local day the period ends against the local date of the
      // last use, three months on.
      const canFreeze =
        freeze.balance > 0 &&
        (!freeze.lastUsedAt ||
          periodStartFor(pEnd, "daily", tz).getTime() >= localMonthsLater(freeze.lastUsedAt, 3, tz).getTime());
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

    const next = nextPeriodStart(pEnd, freq, tz);
    if (next.getTime() <= pEnd.getTime()) {
      // Never walk a zero-length period: stop and re-anchor below.
      logger.warn({ streakId: s.id, periodEnd: pEnd, tz }, "[streaks] next period does not advance; walk stopped");
      break;
    }
    satisfied = false;
    pStart = pEnd;
    pEnd = next;
  }

  // Re-anchor the current period to the calendar period containing `now`.
  const curStart = periodStartFor(now, freq, tz);
  const curEnd = periodEndFor(curStart, freq, tz);
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
  // Start after the badges this run already holds: after a time zone change a
  // milestone near a quarter boundary maps to another quarter, and recomputing
  // it would award a second badge for one milestone.
  const held = await tx
    .select({ year: streakBadgesTable.year, quarterIndex: streakBadgesTable.quarterIndex })
    .from(streakBadgesTable)
    .where(and(eq(streakBadgesTable.userId, s.userId), gte(streakBadgesTable.earnedAt, s.startedAt)))
    .orderBy(streakBadgesTable.year, streakBadgesTable.quarterIndex);
  const last = held[held.length - 1];
  let latest = last ? last.year * 4 + last.quarterIndex - 1 : -1;
  for (let q = held.length + 1; q <= milestones; q++) {
    const at = addMonths(s.startedAt, q * 3);
    // Its quarter in the current zone; after a westward change the run can
    // already hold it, and then it takes the quarter after the run's latest.
    let label = localYear(at, tz) * 4 + localQuarter(at, tz) - 1;
    if (label <= latest) label = latest + 1;
    // A quarter an earlier run's badge holds (the key is per user) is taken:
    // the next one is used, so the milestone still gets one of this run's
    // badges and a repeat read adds nothing.
    for (;;) {
      const year = Math.floor(label / 4);
      const quarterIndex = (label % 4) + 1;
      const inserted = await tx
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
        })
        .returning({ id: streakBadgesTable.id });
      if (inserted.length > 0) break;
      label += 1;
    }
    latest = label;
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
        .where(eq(usersTable.id, userId))
        // Waits for a time zone change in progress (setUserTimezone), so the
        // save uses the committed zone.
        .for("share");
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
        const end = periodEndFor(start, freq, tz);
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
        // Revive: a fresh streak starts here, re-anchored to this save. After a
        // zone change the local period can begin inside the last period logged;
        // then it starts where that one ended, so logged periods never overlap.
        // A save stamped before that end (it waited while a settle logged the
        // period) revives the period holding the end, never a logged one.
        const [lastLogged] = await tx
          .select({ periodEnd: streakPeriodsTable.periodEnd })
          .from(streakPeriodsTable)
          .where(eq(streakPeriodsTable.streakId, s.id))
          .orderBy(desc(streakPeriodsTable.periodEnd))
          .limit(1);
        const loggedEnd = lastLogged?.periodEnd.getTime() ?? 0;
        let start = periodStartFor(new Date(Math.max(at.getTime(), loggedEnd)), freq, tz);
        const end = periodEndFor(start, freq, tz);
        if (start.getTime() < loggedEnd && loggedEnd < end.getTime()) start = new Date(loggedEnd);
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

/**
 * Grant one freeze when due (1 per 3 months, cap 4/year, balance cap 4). Mutates
 * `f` and returns what changed; the caller persists it unless "none". Call under
 * the freeze row lock (ensureFreezeRow).
 */
function grantFreezeIfDue(f: StreakFreeze, tz: string, now: Date): "granted" | "yearReset" | "none" {
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
    return "granted";
  }
  // Persist the year reset even when no grant is due.
  if (f.grantYear === year && f.grantsThisYear === 0) return "yearReset";
  return "none";
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
        if (grantFreezeIfDue(f, u.timezone || "UTC", now) !== "none") await persistFreeze(tx, f);
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
        body: `Your ${unitNoun(freq)} streak window closes ${when}. A small save to any goal or circle keeps your flame alive. No rush.`,
        link: "/streaks",
      });
      // Only for the window it was computed for: a zone change committed since
      // moved the end and cleared the mark, so the new window gets its own.
      await db
        .update(streaksTable)
        .set({ reminderSentPeriodStart: s.currentPeriodStart })
        .where(
          and(
            eq(streaksTable.id, s.id),
            eq(streaksTable.currentPeriodStart, s.currentPeriodStart),
            eq(streaksTable.currentPeriodEnd, s.currentPeriodEnd),
          ),
        );
    } catch (e) {
      logger.error({ err: e, streakId: s.id }, "[streaks] reminder failed");
    }
  }
}

type SettleUser = Pick<User, "timezone" | "streakFrequency" | "vacationStart" | "vacationEnd">;

/**
 * Settle a locked streak whose period has closed: grant a due freeze first (when
 * asked, and only for a streak that isn't broken, as grantFreezes does), then
 * roll the closed periods forward, award badges and persist. Call with the
 * streak row locked, then the freeze row (ensureFreezeRow).
 */
async function settleLocked(
  tx: Tx,
  s: Streak,
  user: SettleUser,
  freeze: StreakFreeze,
  now: Date,
  opts: { grantFreeze: boolean },
): Promise<{ freezeChanged: boolean }> {
  const tz = user.timezone || "UTC";
  const granted = opts.grantFreeze && s.status !== "broken" && grantFreezeIfDue(freeze, tz, now) !== "none";
  const { freezeChanged: used } = await rollForward(tx, s, user, freeze, normFreq(user.streakFrequency), tz, now);
  await awardBadges(tx, s, user, now);
  await persistStreak(tx, s);
  const freezeChanged = granted || used;
  if (freezeChanged) await persistFreeze(tx, freeze);
  return { freezeChanged };
}

/**
 * Settle one streak if its period has closed, in one transaction. The row lock
 * plus the re-check under it make this idempotent: a concurrent caller waits,
 * then sees the new period end and returns.
 */
async function settleDueStreak(streakId: string, now: Date, opts: { grantFreeze: boolean }): Promise<void> {
  await db.transaction(async (tx) => {
    const [locked] = await tx
      .select()
      .from(streaksTable)
      .where(eq(streaksTable.id, streakId))
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
    const freeze = await ensureFreezeRow(tx, locked.userId);
    await settleLocked(tx, { ...locked }, u, freeze, now, opts);
  });
}

/**
 * Settle the account streak before it is read or changed, so a period that has
 * closed is never reported as open (the job runs only every 6 hours). Writes
 * nothing when no period has closed. Never throws: on any failure (a lock wait
 * included) the caller reads the stored row, as before.
 */
async function settleAccountStreak(userId: string, now: Date): Promise<void> {
  try {
    const [s] = await db
      .select({ id: streaksTable.id, currentPeriodEnd: streaksTable.currentPeriodEnd })
      .from(streaksTable)
      .where(
        and(
          eq(streaksTable.userId, userId),
          eq(streaksTable.commitmentType, ACCOUNT),
          eq(streaksTable.commitmentId, userId),
          isNull(streaksTable.archivedAt),
        ),
      );
    if (s && s.currentPeriodEnd.getTime() <= now.getTime()) {
      await settleDueStreak(s.id, now, { grantFreeze: true });
    }
  } catch (err) {
    logger.warn({ err, userId }, "[streaks] settle before read failed");
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
      // grantFreezes has just run.
      await settleDueStreak(row.id, now, { grantFreeze: false });
    } catch (e) {
      logger.error({ err: e, streakId: row.id }, "[streaks] evaluate failed");
    }
  }

  await sendReminders(now);
}

let streakTimer: ReturnType<typeof setInterval> | null = null;
let streakRunning = false;
const STREAK_INTERVAL_MS = 6 * 60 * 60 * 1000; // every 6h; idempotent so frequency is safe

/**
 * One guarded evaluator pass. A failure (e.g. the DB is briefly unreachable in
 * grantFreezes' first query) is logged, never left as an unhandled rejection:
 * on Node that would crash the whole API process, request paths included. A
 * slow pass is never overlapped by the next tick.
 */
async function runStreakPass(label: string): Promise<void> {
  if (streakRunning) return;
  streakRunning = true;
  try {
    await evaluateStreaks();
  } catch (e) {
    logger.error({ err: e }, `[streaks] ${label} evaluate failed`);
  } finally {
    streakRunning = false;
  }
}

/** Start the periodic streak evaluator and run once on boot to recover. */
export async function startStreakLoop(): Promise<void> {
  if (streakTimer) return;
  await runStreakPass("boot");
  streakTimer = setInterval(() => {
    void runStreakPass("scheduled");
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
  /** The zone currentPeriodEnd and the badge quarters are computed in. */
  timezone: string;
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

export async function getStreakOverview(userId: string, now: Date = new Date()): Promise<StreakOverview> {
  // Values are current when the response is built, not up to 6 hours behind.
  await settleAccountStreak(userId, now);

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
    timezone: tz,
  };
}

/**
 * Change the account-streak cadence. Allowed once per calendar year (no-op when
 * unchanged). Re-anchors the streak to a fresh window of the new cadence while
 * keeping the current count — switching cadence never punishes existing progress.
 */
export async function setStreakFrequency(
  userId: string,
  frequency: string,
  now: Date = new Date(),
): Promise<StreakOverview> {
  if (!VALID_FREQ.includes(frequency as Frequency)) {
    throw new AppError("Choose a daily, weekly, or monthly streak.");
  }
  const next = frequency as Frequency;
  // Log a period that has already closed before re-anchoring to the new cadence.
  await settleAccountStreak(userId, now);

  await db.transaction(async (tx) => {
    // The lock setUserTimezone takes first, so a zone change in progress commits
    // before the zone, the cadence and the yearly check are read. Lock order:
    // users, then streak.
    const [user] = await tx
      .select({
        timezone: usersTable.timezone,
        streakFrequency: usersTable.streakFrequency,
        streakFrequencyLastChanged: usersTable.streakFrequencyLastChanged,
      })
      .from(usersTable)
      .where(eq(usersTable.id, userId))
      .for("no key update");
    const tz = user?.timezone || "UTC";
    const current = normFreq(user?.streakFrequency);
    // No-op — don't consume the annual change allowance.
    if (next === current) return;
    if (
      user?.streakFrequencyLastChanged &&
      localYear(user.streakFrequencyLastChanged, tz) === localYear(now, tz)
    ) {
      throw new AppError("You can change your streak frequency once per calendar year.");
    }

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
      const end = periodEndFor(start, next, tz);
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

  return getStreakOverview(userId, now);
}

/**
 * The open period's home end: the end it had in the zone it opened in. While it
 * is still the old zone's own period (always so at the first change in a
 * period) that is its current end. Otherwise it is derived from the start (a
 * day, a week, or the days of the start's UTC month), unless the period is too
 * short to have opened at its start: then its current end. No home end is
 * stored, so after two or more changes in one period it is an estimate:
 *  - A: the home zone has a DST change inside the period, which the derivation
 *    misses (an hour; two for Antarctica/Troll).
 *  - B: the own-period test matches a later zone that shares the period's
 *    start but ends it at another hour (off by that difference).
 *  - C: a revive trimmed to start where the last logged period ended (R7) is
 *    derived as if it opened at its start, off by the trim, when the trim
 *    leaves at least half a period less three hours: in practice only daily
 *    periods (a trim under 15 hours) end up elsewhere. A shorter one uses its
 *    current end: exact at the first change after the revive.
 * So a period not saved yet can end up to an hour more than the largest DST
 * shift in the chain before its true home end, and with Troll a round trip can
 * add a whole period. A saved day can fall on the other side of a 12-hour tie:
 * a day later (merged with the next local day) or a day earlier (closed at
 * once as kept).
 */
function homeEnd(s: Streak, freq: Frequency, oldTz: string): number {
  const start = s.currentPeriodStart.getTime();
  const end = s.currentPeriodEnd.getTime();
  if (
    periodStartFor(s.currentPeriodStart, freq, oldTz).getTime() === start &&
    nextPeriodStart(s.currentPeriodStart, freq, oldTz).getTime() === end
  ) {
    return end;
  }
  let derived: number;
  if (freq === "daily") derived = start + DAY_MS;
  else if (freq === "weekly") derived = start + 7 * DAY_MS;
  else {
    const mid = new Date(start + 14 * HOUR_MS);
    derived = start + new Date(Date.UTC(mid.getUTCFullYear(), mid.getUTCMonth() + 1, 0)).getUTCDate() * DAY_MS;
  }
  // A period that opened at its start keeps at least half a period, less two
  // and a half hours of DST shifts, after any change: its end is the boundary
  // nearest its home end, or later. A shorter one opened later (C).
  if (end - start < (derived - start) / 2 - 3 * HOUR_MS) return end;
  return derived;
}

/**
 * Where the open period ends after a change from `oldTz` to `tz` (lead ruling
 * B-SAFE-1, revised, with the round 3 amendments and the round 4 fixes). Every
 * candidate is a period start in the new zone, measured from the home end,
 * never from the current end, so the result does not depend on the path: a
 * chain of changes ends where one change from the home zone at the time of the
 * last change would (apart from the cases in homeEnd).
 *  - Saved: the boundary nearest the home end (a tie goes to the later one). It
 *    may have passed already; the caller then closes the period.
 *  - Not saved yet: the first boundary at or after one hour before the home
 *    end, or, if that has passed, the first boundary after `now`.
 * Never at or before the period's start (a guard): then the first boundary
 * after the start. An end that has passed is never before the start of the new
 * zone's period holding `now`, so the close logs only the kept period and never
 * walks a whole new-zone period as not saved.
 */
function endAfterZoneChange(s: Streak, freq: Frequency, oldTz: string, tz: string, now: Date): Date {
  const home = homeEnd(s, freq, oldTz);
  let end: Date;
  if (s.currentPeriodSatisfied) {
    const before = periodStartFor(new Date(home), freq, tz);
    const after = periodEndFor(before, freq, tz);
    end = home - before.getTime() < after.getTime() - home ? before : after;
  } else {
    const floor = home - HOUR_MS;
    const boundary = periodStartFor(new Date(floor), freq, tz);
    end = boundary.getTime() < floor ? periodEndFor(boundary, freq, tz) : boundary;
    if (end.getTime() <= now.getTime()) end = periodEndFor(periodStartFor(now, freq, tz), freq, tz);
  }
  if (end.getTime() <= s.currentPeriodStart.getTime()) {
    end = periodEndFor(periodStartFor(s.currentPeriodStart, freq, tz), freq, tz);
  }
  if (end.getTime() <= now.getTime()) end = new Date(Math.max(end.getTime(), periodStartFor(now, freq, tz).getTime()));
  return end;
}

/**
 * Store the user's IANA time zone (already validated) and move the open streak
 * period onto it, in one transaction. A period that has closed is settled in the
 * old zone first. Then only the open period's end moves, to a period start in
 * the new zone (endAfterZoneChange), measured from its home end (homeEnd): the
 * end it had in the zone it opened in. A saved period ends at the boundary
 * nearest its home end; a period not saved yet at the first one at or after an
 * hour before its home end. A save already made in it is kept. Lead ruling
 * B-SAFE-1 (revised, with the round 3 amendments and the round 4 fixes), in
 * order of priority, with "home end" meaning homeEnd's value (its cases A to C
 * say where that differs from the true one):
 *  - G1: the change alone never uses a freeze or breaks a streak. It never
 *    closes a period not saved yet, and that period never ends more than an
 *    hour before its home end (a DST shift, or a zone an hour east ending at
 *    its own midnight), however many changes it goes through. A saved period
 *    the change closes is logged as one saved row (G2).
 *  - G2: a saved period ends at the boundary nearest its home end, so it is not
 *    merged with the next local period and the person's next local save counts
 *    as a new step. When that boundary has already passed, the period is closed
 *    now as kept, through the settle, up to the start of the new zone's period
 *    holding `now`, which opens. The count does not change: the save already
 *    counted. The closed row then also holds any whole new-zone periods between
 *    that boundary and `now`, which an earlier stretch gave the period while it
 *    was not saved yet. A break in progress is logged as the settle logs it.
 *    The close does not look at when the save was made: a save between that
 *    boundary and the change stays with the closed period, so a save just
 *    after it in the same local period can count again (an accepted
 *    trade-off).
 *  - G3: the start never moves, and the end is always after it, so no local
 *    period is counted twice apart from G2's trade-off. A period not saved yet
 *    ends at the first boundary at or after an hour before its home end, so
 *    less than one new-zone period after that. When that boundary has already
 *    passed (a change in the period's last hour, or after its home end
 *    following an earlier stretch), it ends at the first boundary after `now`.
 *    G1 outranks G3, so the open period can then hold two whole new-zone
 *    periods; it ends at most one new-zone period after the change.
 * A later end clears the reminder mark, so the closing reminder can go out
 * again. The same zone again is a no-op. Lock order: users (FOR NO KEY UPDATE:
 * recordSave's FOR SHARE and setStreakFrequency's lock wait for it, but the
 * foreign-key check of a settle's freeze or badge insert does not), then
 * streak, then freeze.
 */
export async function setUserTimezone(userId: string, tz: string, now: Date = new Date()): Promise<void> {
  await db.transaction(async (tx) => {
    const [user] = await tx
      .select({
        timezone: usersTable.timezone,
        streakFrequency: usersTable.streakFrequency,
        vacationStart: usersTable.vacationStart,
        vacationEnd: usersTable.vacationEnd,
      })
      .from(usersTable)
      .where(eq(usersTable.id, userId))
      .for("no key update");
    if (!user || (user.timezone || "UTC") === tz) return;

    const [s] = await tx
      .select()
      .from(streaksTable)
      .where(
        and(
          eq(streaksTable.userId, userId),
          eq(streaksTable.commitmentType, ACCOUNT),
          eq(streaksTable.commitmentId, userId),
          isNull(streaksTable.archivedAt),
        ),
      )
      .for("update");
    if (s) {
      if (s.currentPeriodEnd.getTime() <= now.getTime()) {
        const freeze = await ensureFreezeRow(tx, userId);
        await settleLocked(tx, s, user, freeze, now, { grantFreeze: true });
      }
      const oldEnd = s.currentPeriodEnd.getTime();
      s.currentPeriodEnd = endAfterZoneChange(s, normFreq(user.streakFrequency), user.timezone || "UTC", tz, now);
      if (s.currentPeriodEnd.getTime() <= now.getTime()) {
        // Saved, and its nearest new-zone boundary has passed: close it as kept.
        const freeze = await ensureFreezeRow(tx, userId);
        await settleLocked(tx, s, { ...user, timezone: tz }, freeze, now, { grantFreeze: true });
      } else {
        await persistStreak(tx, s);
        if (s.currentPeriodEnd.getTime() > oldEnd) {
          await tx.update(streaksTable).set({ reminderSentPeriodStart: null }).where(eq(streaksTable.id, s.id));
        }
      }
    }

    await tx.update(usersTable).set({ timezone: tz }).where(eq(usersTable.id, userId));
  });
}

export async function setReminderOptIn(userId: string, optIn: boolean): Promise<{ optIn: boolean }> {
  await db.update(usersTable).set({ streakReminderOptIn: optIn }).where(eq(usersTable.id, userId));
  return { optIn };
}

/** Start the single annual vacation (<=30 days, once per calendar year). */
export async function startVacation(
  userId: string,
  days: number,
  now: Date = new Date(),
): Promise<StreakOverview> {
  if (!Number.isFinite(days) || days < 1 || days > 30) {
    throw new AppError("Vacation must be between 1 and 30 days");
  }
  // Log a period that has already closed before the pause.
  await settleAccountStreak(userId, now);
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
  return getStreakOverview(userId, now);
}

/** End the vacation early (forfeits the rest; the annual allowance stays spent). */
export async function endVacation(userId: string, now: Date = new Date()): Promise<StreakOverview> {
  // Log periods that closed during the break while it still counts as one.
  await settleAccountStreak(userId, now);
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
  return getStreakOverview(userId, now);
}
