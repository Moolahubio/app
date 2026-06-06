import { and, eq, isNull, lte, gt, ne, inArray, sql, count } from "drizzle-orm";
import {
  db,
  streaksTable,
  streakPeriodsTable,
  streakFreezesTable,
  streakBadgesTable,
  usersTable,
  goalsTable,
  circlesTable,
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
 * Two write paths feed the engine:
 *  - recordSave(): called after a ledger commit in allocateToGoal()/contribute().
 *    Marks the current period satisfied and increments once per period. Idempotent.
 *  - evaluateStreaks(): scheduled job that rolls closed periods forward, applies
 *    freezes / vacation / breaks, awards calendar-time badges, grants freezes, and
 *    enqueues at most one reminder per period. Idempotent via streak_periods.
 */

export type CommitmentType = "goal" | "circle";
export type Frequency = "weekly" | "biweekly" | "monthly";

export type Commitment = {
  type: CommitmentType;
  id: string;
  frequency: string;
};

const DAY_MS = 86_400_000;
const MAX_FREEZES = 4;
const ROLL_GUARD = 600;

function normFreq(f: string): Frequency {
  return f === "biweekly" || f === "monthly" ? f : "weekly";
}

function periodLenMs(f: Frequency): number {
  return (f === "biweekly" ? 14 : 7) * DAY_MS;
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

type Period = { index: number; start: Date; end: Date };

function periodAt(anchor: Date, freq: Frequency, index: number): Period {
  if (freq === "monthly") {
    return { index, start: addMonths(anchor, index), end: addMonths(anchor, index + 1) };
  }
  const len = periodLenMs(freq);
  return {
    index,
    start: new Date(anchor.getTime() + index * len),
    end: new Date(anchor.getTime() + (index + 1) * len),
  };
}

/** The period that contains `at`, anchored to `anchor`. */
function periodFor(anchor: Date, freq: Frequency, at: Date): Period {
  if (at.getTime() <= anchor.getTime()) return periodAt(anchor, freq, 0);
  if (freq === "monthly") {
    let n = monthsBetween(anchor, at);
    while (addMonths(anchor, n + 1).getTime() <= at.getTime()) n += 1;
    while (n > 0 && addMonths(anchor, n).getTime() > at.getTime()) n -= 1;
    return periodAt(anchor, freq, n);
  }
  const len = periodLenMs(freq);
  const n = Math.max(0, Math.floor((at.getTime() - anchor.getTime()) / len));
  return periodAt(anchor, freq, n);
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
  now: Date,
): Promise<{ streakChanged: boolean; freezeChanged: boolean }> {
  const freq = normFreq(s.frequency);
  if (s.currentPeriodEnd.getTime() > now.getTime()) return { streakChanged: false, freezeChanged: false };

  const anchor = s.startedAt;
  const startIdx = periodFor(anchor, freq, s.currentPeriodStart).index;
  const target = periodFor(anchor, freq, now);
  let freezeChanged = false;
  let guard = 0;

  for (let idx = startIdx; idx < target.index && guard < ROLL_GUARD; idx++, guard++) {
    const p = periodAt(anchor, freq, idx);
    const satisfied = idx === startIdx && s.currentPeriodSatisfied;
    const onVacation = intervalsOverlap(p.start, p.end, user.vacationStart, user.vacationEnd);
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
        (!freeze.lastUsedAt || p.end.getTime() >= addMonths(freeze.lastUsedAt, 3).getTime());
      if (canFreeze) {
        freeze.balance -= 1;
        freeze.usedTotal += 1;
        freeze.lastUsedAt = p.end;
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
        periodStart: p.start,
        periodEnd: p.end,
        outcome,
        saveCount: outcome === "saved" ? 1 : 0,
      })
      .onConflictDoNothing({ target: [streakPeriodsTable.streakId, streakPeriodsTable.periodStart] });
  }

  // Re-anchor the current period to the one containing `now`.
  s.currentPeriodStart = target.start;
  s.currentPeriodEnd = target.end;
  s.currentPeriodSatisfied = false;
  if (s.status !== "broken" && !intervalsOverlap(target.start, target.end, user.vacationStart, user.vacationEnd)) {
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
 * Mark the current period satisfied for a (user, commitment), creating the
 * streak on first save. Increments the streak once per period; idempotent for
 * repeat saves in the same period. Call AFTER the ledger commit. Never throws.
 */
export async function recordSave(
  userId: string,
  commitment: Commitment,
  saveRef: string,
  at: Date = new Date(),
): Promise<void> {
  const freq = normFreq(commitment.frequency);
  try {
    await db.transaction(async (tx) => {
      const [existing] = await tx
        .select()
        .from(streaksTable)
        .where(
          and(
            eq(streaksTable.userId, userId),
            eq(streaksTable.commitmentType, commitment.type),
            eq(streaksTable.commitmentId, commitment.id),
          ),
        )
        .for("update");

      if (!existing) {
        const p = periodFor(at, freq, at);
        await tx.insert(streaksTable).values({
          userId,
          commitmentType: commitment.type,
          commitmentId: commitment.id,
          frequency: freq,
          startedAt: at,
          currentCount: 1,
          bestCount: 1,
          status: "active",
          currentPeriodStart: p.start,
          currentPeriodEnd: p.end,
          currentPeriodSatisfied: true,
          lastSaveRef: saveRef,
        });
        return;
      }

      const s: Streak = { ...existing, frequency: freq };
      const [user] = await tx
        .select({ vacationStart: usersTable.vacationStart, vacationEnd: usersTable.vacationEnd })
        .from(usersTable)
        .where(eq(usersTable.id, userId));
      const freeze = await ensureFreezeRow(tx, userId);

      const { freezeChanged } = await rollForward(tx, s, user ?? { vacationStart: null, vacationEnd: null }, freeze, at);

      // Apply the save to the now-current period.
      if (s.status === "broken" || s.currentCount === 0) {
        // Revive: a fresh streak starts here, re-anchored to this save.
        const p = periodFor(at, freq, at);
        s.startedAt = at;
        s.currentPeriodStart = p.start;
        s.currentPeriodEnd = p.end;
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
    logger.error({ err: e, userId, commitment }, "[streaks] recordSave failed");
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
      commitmentName: sql<string | null>`null`,
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

  for (const { streak: s } of rows) {
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

      const link = s.commitmentType === "goal" ? `/goals/${s.commitmentId}` : `/circles/${s.commitmentId}`;
      await notify(s.userId, {
        type: "streak_reminder",
        title: "Keep your streak going",
        body: "A small save before this period closes keeps your flame alive. No rush — whatever works for you.",
        link,
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
            vacationStart: usersTable.vacationStart,
            vacationEnd: usersTable.vacationEnd,
          })
          .from(usersTable)
          .where(eq(usersTable.id, locked.userId));
        const u = user ?? { timezone: "UTC", vacationStart: null, vacationEnd: null };
        const freeze = await ensureFreezeRow(tx, locked.userId);

        const s: Streak = { ...locked };
        const { freezeChanged } = await rollForward(tx, s, u, freeze, now);
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

export type StreakCommitmentView = {
  id: string;
  commitmentType: CommitmentType;
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

export type StreakOverview = {
  hero: {
    count: number;
    status: string;
    commitmentName: string | null;
    emoji: string | null;
  } | null;
  lifetimeBest: number;
  totalPeriodsSaved: number;
  commitments: StreakCommitmentView[];
  freezes: { balance: number; usedTotal: number };
  badges: StreakBadgeView[];
  reminderOptIn: boolean;
  vacation: { active: boolean; start: string | null; end: string | null; usedThisYear: boolean };
};

async function resolveNames(
  rows: Streak[],
): Promise<Map<string, { name: string; emoji: string | null }>> {
  const out = new Map<string, { name: string; emoji: string | null }>();
  const goalIds = rows.filter((r) => r.commitmentType === "goal").map((r) => r.commitmentId);
  const circleIds = rows.filter((r) => r.commitmentType === "circle").map((r) => r.commitmentId);
  if (goalIds.length) {
    const gs = await db
      .select({ id: goalsTable.id, name: goalsTable.name, emoji: goalsTable.emoji })
      .from(goalsTable)
      .where(inArray(goalsTable.id, goalIds));
    for (const g of gs) out.set(`goal:${g.id}`, { name: g.name, emoji: g.emoji });
  }
  if (circleIds.length) {
    const cs = await db
      .select({ id: circlesTable.id, name: circlesTable.name })
      .from(circlesTable)
      .where(inArray(circlesTable.id, circleIds));
    for (const c of cs) out.set(`circle:${c.id}`, { name: c.name, emoji: null });
  }
  return out;
}

export async function getStreakOverview(userId: string): Promise<StreakOverview> {
  const [user] = await db
    .select({
      timezone: usersTable.timezone,
      streakReminderOptIn: usersTable.streakReminderOptIn,
      vacationStart: usersTable.vacationStart,
      vacationEnd: usersTable.vacationEnd,
      vacationYearUsed: usersTable.vacationYearUsed,
    })
    .from(usersTable)
    .where(eq(usersTable.id, userId));

  const rows = await db
    .select()
    .from(streaksTable)
    .where(and(eq(streaksTable.userId, userId), isNull(streaksTable.archivedAt)));

  const names = await resolveNames(rows);
  const commitments: StreakCommitmentView[] = rows.map((r) => {
    const info = names.get(`${r.commitmentType}:${r.commitmentId}`);
    return {
      id: r.id,
      commitmentType: r.commitmentType as CommitmentType,
      commitmentId: r.commitmentId,
      commitmentName: info?.name ?? "Savings",
      emoji: info?.emoji ?? null,
      frequency: r.frequency,
      currentCount: r.currentCount,
      bestCount: r.bestCount,
      status: r.status,
      currentPeriodEnd: r.currentPeriodEnd.toISOString(),
      currentPeriodSatisfied: r.currentPeriodSatisfied,
    };
  });

  const alive = commitments.filter((c) => (ALIVE_STATUSES as readonly string[]).includes(c.status));
  const hero = alive.reduce<StreakCommitmentView | null>((best, c) => {
    return !best || c.currentCount > best.currentCount ? c : best;
  }, null);

  const lifetimeBest = rows.reduce((m, r) => Math.max(m, r.bestCount, r.currentCount), 0);

  const streakIds = rows.map((r) => r.id);
  let totalPeriodsSaved = 0;
  if (streakIds.length) {
    const [agg] = await db
      .select({ saved: count() })
      .from(streakPeriodsTable)
      .where(and(inArray(streakPeriodsTable.streakId, streakIds), eq(streakPeriodsTable.outcome, "saved")));
    totalPeriodsSaved = Number(agg?.saved ?? 0);
  }
  // Include the currently-satisfied (open) periods, which aren't logged yet.
  totalPeriodsSaved += commitments.filter((c) => c.currentPeriodSatisfied).length;

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

  const tz = user?.timezone || "UTC";
  const now = new Date();
  const vacActive = Boolean(
    user?.vacationStart && user?.vacationEnd &&
      user.vacationStart.getTime() <= now.getTime() &&
      now.getTime() < user.vacationEnd.getTime(),
  );

  return {
    hero: hero ? { count: hero.currentCount, status: hero.status, commitmentName: hero.commitmentName, emoji: hero.emoji } : null,
    lifetimeBest,
    totalPeriodsSaved,
    commitments,
    freezes: { balance: freeze?.balance ?? 0, usedTotal: freeze?.usedTotal ?? 0 },
    badges: badgeRows.map((b) => ({
      badgeKey: b.badgeKey,
      year: b.year,
      quarterIndex: b.quarterIndex,
      earnedAt: b.earnedAt.toISOString(),
    })),
    reminderOptIn: user?.streakReminderOptIn ?? false,
    vacation: {
      active: vacActive,
      start: user?.vacationStart?.toISOString() ?? null,
      end: user?.vacationEnd?.toISOString() ?? null,
      usedThisYear: user?.vacationYearUsed === localYear(now, tz),
    },
  };
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
