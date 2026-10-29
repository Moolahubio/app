/**
 * Streak engine smoke test against the real DB.
 * Run: pnpm --filter @workspace/api-server run test:streaks
 *
 * Validates the new streak tables line up with the engine: a save creates a
 * streak, the same save reference is idempotent (no farming a streak by
 * replaying one save), a second distinct save in a later period advances the
 * count, and the read projection returns a coherent overview. Then the
 * settle-before-read cases: a read, a cadence change and a break settle a
 * closed period first, exactly once, even when called concurrently. Then the
 * time zone cases: a zone change settles in the old zone and moves only the open
 * period's end, so no local period is counted twice and no badge is re-keyed;
 * an open period not saved yet never loses more than an hour, so the change
 * alone never uses a freeze; a saved one ends at the nearest local boundary, so
 * the next local period's save counts (lead ruling B-SAFE-1 revised, worked
 * examples 1 to 14); and a change racing a settle or a save neither deadlocks
 * nor lets the save use the old zone. Then the round 3 rulings: a day whose
 * local midnight a DST jump skips starts after the jump; a chain of changes or
 * a round trip ends where one change from the period's home zone would; a
 * change in a period's last hour, a save between the new boundary and a change,
 * the freeze cooldown in local days, badge labels, a revive after a break, the
 * reminder mark, a cadence change racing a zone change, breaks and the job.
 * Then fix round 4: a change that closes a period at once logs one saved row
 * however far back its boundary lies, a change after a trimmed revive, a save
 * stamped before a settle, a badge after an earlier run, and the freeze
 * cooldown on the local calendar.
 * Every call passes an explicit `now`, so the result never depends on the real
 * clock. Cleans up after itself in a finally block. The last case runs the job,
 * which touches every streak in the database: do not run this file at the same
 * time as another suite on the same database.
 */
import { randomUUID } from "node:crypto";
import {
  db,
  pool,
  usersTable,
  streaksTable,
  streakPeriodsTable,
  streakFreezesTable,
  streakBadgesTable,
} from "@workspace/db";
import { and, asc, eq, inArray } from "drizzle-orm";
import { isDeepStrictEqual } from "node:util";
import {
  recordSave,
  getStreakOverview,
  setStreakFrequency,
  startVacation,
  endVacation,
  setUserTimezone,
  evaluateStreaks,
  type Frequency,
} from "./streaks";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(`ASSERT FAILED: ${msg}`);
}

const userIds: string[] = [];

// Every connection this process opens carries this name (pg reads PGAPPNAME when
// it opens one, and none is open yet), so lockWaiters counts only this test's
// own lock waiters, never another session's on the database.
const APP_NAME = `streaks-e2e-${process.pid}`;
process.env.PGAPPNAME = APP_NAME;

// Weekly periods in UTC (Mondays 00:00Z).
const W1 = new Date("2026-01-05T00:00:00Z");
const W2 = new Date("2026-01-12T00:00:00Z");
const W3 = new Date("2026-01-19T00:00:00Z");
const W4 = new Date("2026-01-26T00:00:00Z");
const SAVE_W1 = new Date("2026-01-05T12:00:00Z");

/** A fresh user, weekly on UTC unless a cadence or a zone is given. */
async function newUser(label: string, cadence: Frequency = "weekly", zone = "UTC"): Promise<string> {
  const id = randomUUID();
  await db.insert(usersTable).values({
    id,
    name: `Streak ${label}`,
    email: `streak-${label}-${id}@test.local`,
    timezone: zone,
    streakFrequency: cadence,
  });
  userIds.push(id);
  return id;
}

async function accountStreak(userId: string) {
  const [s] = await db
    .select()
    .from(streaksTable)
    .where(and(eq(streaksTable.userId, userId), eq(streaksTable.commitmentType, "account")));
  return s;
}

async function periodRows(userId: string) {
  const s = await accountStreak(userId);
  if (!s) return [];
  return db
    .select()
    .from(streakPeriodsTable)
    .where(eq(streakPeriodsTable.streakId, s.id))
    .orderBy(asc(streakPeriodsTable.periodStart));
}

async function freezeRow(userId: string) {
  const [f] = await db.select().from(streakFreezesTable).where(eq(streakFreezesTable.userId, userId));
  return f;
}

const iso = (d: Date) => d.toISOString();
const outcomes = (rows: { outcome: string }[]) => rows.map((r) => r.outcome).join(",");

// An oracle for local periods, independent of the engine's maths: a period
// starts at the first instant whose local date is its first date.

/** The local date of an instant in `zone`, as yyyymmdd. */
function localDate(at: number, zone: string): number {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit" })
    .formatToParts(new Date(at));
  const p = Object.fromEntries(parts.map((x) => [x.type, x.value]));
  return Number(p.year) * 10000 + Number(p.month) * 100 + Number(p.day);
}

/** The first instant whose local date in `zone` is `date` or later, searched within 40 days of `near`. */
function firstInstantOf(date: number, zone: string, near: number): number {
  let lo = near - 40 * 86_400_000;
  let hi = near + 40 * 86_400_000;
  while (hi - lo > 1) {
    const mid = Math.floor((lo + hi) / 2);
    if (localDate(mid, zone) >= date) hi = mid;
    else lo = mid;
  }
  return hi;
}

/** The bounds of the `zone` period (weeks start Monday) holding `at`. */
function localPeriod(at: Date, cadence: Frequency, zone: string): { start: number; end: number } {
  const d = localDate(at.getTime(), zone);
  const day = Date.UTC(Math.floor(d / 10000), (Math.floor(d / 100) % 100) - 1, d % 100);
  const dayNum = (t: number) => {
    const x = new Date(t);
    return x.getUTCFullYear() * 10000 + (x.getUTCMonth() + 1) * 100 + x.getUTCDate();
  };
  let first = day;
  let next = day + 86_400_000;
  if (cadence === "weekly") {
    first = day - ((new Date(day).getUTCDay() + 6) % 7) * 86_400_000;
    next = first + 7 * 86_400_000;
  } else if (cadence === "monthly") {
    const x = new Date(day);
    first = Date.UTC(x.getUTCFullYear(), x.getUTCMonth(), 1);
    next = Date.UTC(x.getUTCFullYear(), x.getUTCMonth() + 1, 1);
  }
  return { start: firstInstantOf(dayNum(first), zone, at.getTime()), end: firstInstantOf(dayNum(next), zone, at.getTime()) };
}

/** The original smoke test: create, idempotent replay, per-period cap, advance, cadence change. */
async function smoke() {
  const userId = await newUser("smoke");
  const t0 = new Date("2026-01-05T12:00:00Z"); // a Monday (start of an ISO week)
  const refA = `save-${randomUUID()}`;

  const heroCount = async (now: Date): Promise<number> => {
    const ov = await getStreakOverview(userId, now);
    assert(ov.hero, "hero should exist");
    return ov.hero.count;
  };

  // First save (any deposit) lights the single account streak at 1.
  await recordSave(userId, refA, t0);
  let ov = await getStreakOverview(userId, t0);
  assert(ov.hero, "hero should exist after first save");
  assert(ov.hero.count === 1, `expected count 1, got ${ov.hero.count}`);
  assert(ov.frequency === "weekly", `default frequency should be weekly, got ${ov.frequency}`);
  assert(ov.currentPeriodSatisfied, "current period should be satisfied");
  assert(ov.commitments.length === 0, "per-commitment streaks are retired (empty list)");

  // Replaying the SAME save reference must NOT advance (idempotent — no farming
  // a streak from one deposit).
  await recordSave(userId, refA, t0);
  assert((await heroCount(t0)) === 1, "replay must stay at 1");

  // A second deposit in the SAME week must not advance either (once per period).
  const tSameWeek = new Date("2026-01-07T09:00:00Z");
  await recordSave(userId, `save-${randomUUID()}`, tSameWeek);
  assert((await heroCount(tSameWeek)) === 1, "same-week second save must stay at 1");

  // A distinct save in the NEXT calendar week advances the streak to 2.
  const t1 = new Date("2026-01-12T12:00:00Z"); // the following Monday
  await recordSave(userId, `save-${randomUUID()}`, t1);
  assert((await heroCount(t1)) === 2, "expected count 2 after next-week save");

  ov = await getStreakOverview(userId, t1);
  assert(ov.lifetimeBest >= 2, `lifetimeBest should be >= 2, got ${ov.lifetimeBest}`);
  assert(ov.canChangeFrequency, "frequency should be changeable before any change");

  // Switching cadence keeps the count and consumes the annual allowance. A fixed
  // `now` keeps the once-per-calendar-year check independent of the real year.
  const t1Plus = new Date("2026-01-13T12:00:00Z");
  ov = await setStreakFrequency(userId, "daily", t1Plus);
  assert(ov.frequency === "daily", `frequency should now be daily, got ${ov.frequency}`);
  assert(ov.hero && ov.hero.count === 2, "count must be preserved across a cadence change");
  assert(!ov.canChangeFrequency, "second change in the same year should be blocked");

  let blocked = false;
  try {
    await setStreakFrequency(userId, "monthly", t1Plus);
  } catch {
    blocked = true;
  }
  assert(blocked, "changing frequency twice in one calendar year must throw");
}

// --- C29: settle a closed period before answering ----------------------------

async function satisfiedPeriodCloses() {
  const u = await newUser("c29-close");
  await recordSave(u, `save-${randomUUID()}`, SAVE_W1);
  const now = new Date("2026-01-12T10:00:00Z");
  const ov = await getStreakOverview(u, now);
  assert(!ov.currentPeriodSatisfied, "the new week is not saved yet");
  assert(ov.atRisk, "the new week is at risk");
  assert(ov.hero?.count === 1 && ov.hero.status === "active", `hero 1 active, got ${JSON.stringify(ov.hero)}`);
  assert(ov.currentPeriodEnd === "2026-01-19T00:00:00.000Z", `period ends 01-19, got ${ov.currentPeriodEnd}`);
  assert(ov.totalPeriodsSaved === 1, `one period saved, got ${ov.totalPeriodsSaved}`);
  const rows = await periodRows(u);
  assert(rows.length === 1, `one period row, got ${rows.length}`);
  assert(iso(rows[0].periodStart) === iso(W1) && iso(rows[0].periodEnd) === iso(W2), "the row is week 1");
  assert(rows[0].outcome === "saved", `week 1 saved, got ${rows[0].outcome}`);

  // The same read twice gives the same answer and writes nothing more.
  const again = await getStreakOverview(u, now);
  assert(isDeepStrictEqual(again, ov), "a repeat read returns an identical overview");
  assert((await periodRows(u)).length === 1, "still one period row");
}

async function concurrentReads() {
  const u = await newUser("c29-concurrent");
  await recordSave(u, `save-${randomUUID()}`, SAVE_W1);
  const now = new Date("2026-01-20T12:00:00Z"); // two periods after the save
  const views = await Promise.all(Array.from({ length: 5 }, () => getStreakOverview(u, now)));
  const rows = await periodRows(u);
  assert(rows.length === 2, `one row per closed period (2), got ${rows.length}`);
  assert(new Set(rows.map((r) => iso(r.periodStart))).size === 2, "no period is logged twice");
  const f = await freezeRow(u);
  assert(f && f.usedTotal <= 1, `at most one freeze used, got ${f?.usedTotal}`);
  assert(f && f.grantedTotal <= 1, `at most one freeze granted, got ${f?.grantedTotal}`);
  for (const v of views) assert(v.hero?.count === 1, "every concurrent read sees count 1");
}

async function missedWithFreezeDue() {
  const u = await newUser("c29-freeze");
  await recordSave(u, `save-${randomUUID()}`, SAVE_W1);
  assert(!(await freezeRow(u)), "a first save creates no freeze row");
  const now = new Date("2026-01-20T12:00:00Z"); // week 3
  const ov = await getStreakOverview(u, now);
  const rows = await periodRows(u);
  assert(outcomes(rows) === "saved,frozen", `week 1 saved, week 2 frozen, got ${outcomes(rows)}`);
  assert(iso(rows[1].periodStart) === iso(W2), "the frozen row is week 2");
  assert(ov.hero?.status === "frozen", `status frozen, got ${ov.hero?.status}`);
  const f = await freezeRow(u);
  assert(f?.grantedTotal === 1 && f.usedTotal === 1 && f.balance === 0, `granted then used, got ${JSON.stringify(f)}`);

  const before = await accountStreak(u);
  await getStreakOverview(u, now);
  const after = await accountStreak(u);
  assert(outcomes(await periodRows(u)) === "saved,frozen", "a repeat read logs nothing");
  assert(isDeepStrictEqual(await freezeRow(u), f), "a repeat read leaves the freezes alone");
  assert(iso(after.updatedAt) === iso(before.updatedAt), "a repeat read leaves the streak row alone");
}

async function missedTwiceNoFreeze() {
  const u = await newUser("c29-break");
  await recordSave(u, `save-${randomUUID()}`, SAVE_W1);
  // No grant is due at the read: one was given at that very moment.
  await db.insert(streakFreezesTable).values({
    userId: u,
    balance: 0,
    lastGrantedAt: new Date("2026-01-27T12:00:00Z"),
    grantYear: 2026,
    grantsThisYear: 1,
  });
  const ov = await getStreakOverview(u, new Date("2026-01-27T12:00:00Z")); // week 4
  assert(ov.hero === null, `a broken streak has no hero, got ${JSON.stringify(ov.hero)}`);
  assert(ov.lifetimeBest === 1, `lifetimeBest 1, got ${ov.lifetimeBest}`);
  const rows = await periodRows(u);
  assert(outcomes(rows) === "saved,missed,missed", `saved, missed, missed, got ${outcomes(rows)}`);
  assert(iso(rows[2].periodStart) === iso(W3), "the last row is week 3");
}

async function archivedStreakUntouched() {
  const u = await newUser("c29-archived");
  await recordSave(u, `save-${randomUUID()}`, SAVE_W1);
  await db.update(streaksTable).set({ archivedAt: new Date("2026-01-06T00:00:00Z") }).where(eq(streaksTable.userId, u));
  const before = await accountStreak(u);
  const ov = await getStreakOverview(u, new Date("2026-01-27T12:00:00Z"));
  const after = await accountStreak(u);
  assert(ov.hero === null, "an archived streak is not shown");
  assert(isDeepStrictEqual(after, before), "the archived row is untouched");
  assert((await periodRows(u)).length === 0, "no period row is written");
}

/** A streak whose first quarterly milestone (2026-04-01T05:00Z) falls in Q2 in UTC. */
async function insertQuarterStreak(u: string) {
  await db.insert(streaksTable).values({
    userId: u,
    commitmentType: "account",
    commitmentId: u,
    frequency: "weekly",
    startedAt: new Date("2026-01-01T05:00:00Z"),
    status: "active",
    currentCount: 14,
    bestCount: 14,
    currentPeriodStart: new Date("2026-03-30T00:00:00Z"),
    currentPeriodEnd: new Date("2026-04-06T00:00:00Z"),
    currentPeriodSatisfied: true,
  });
}

async function badgeAwardedOnce() {
  const u = await newUser("c29-badge");
  await insertQuarterStreak(u);
  const now = new Date("2026-04-06T12:00:00Z");
  let ov = await getStreakOverview(u, now);
  assert(ov.badges.length === 1 && ov.badges[0].badgeKey === "2026-q2", `one badge 2026-q2, got ${JSON.stringify(ov.badges)}`);
  ov = await getStreakOverview(u, now);
  assert(ov.badges.length === 1, "a repeat read awards nothing more");
  const rows = await db.select().from(streakBadgesTable).where(eq(streakBadgesTable.userId, u));
  assert(rows.length === 1, `one badge row, got ${rows.length}`);
}

async function settleBeforeBreak() {
  const u = await newUser("c29-break-writes");
  await recordSave(u, `save-${randomUUID()}`, SAVE_W1);
  let ov = await startVacation(u, 7, new Date("2026-01-20T12:00:00Z"));
  assert(outcomes(await periodRows(u)) === "saved,frozen", "week 2 is logged frozen before the pause");
  assert(ov.hero?.status === "paused", `status paused, got ${ov.hero?.status}`);
  assert(ov.vacation.active, "the break is active");

  // The week 3 boundary passed during the break.
  ov = await endVacation(u, new Date("2026-01-26T12:00:00Z"));
  assert(ov.hero?.status === "active", `status active after the break, got ${ov.hero?.status}`);
  const rows = await periodRows(u);
  assert(outcomes(rows) === "saved,frozen,paused", `week 3 logged paused, got ${outcomes(rows)}`);
  assert(iso(rows[2].periodStart) === iso(W3) && iso(rows[2].periodEnd) === iso(W4), "the paused row is week 3");
}

async function settleBeforeCadenceChange() {
  const u = await newUser("c29-cadence");
  await recordSave(u, `save-${randomUUID()}`, SAVE_W1);
  const ov = await setStreakFrequency(u, "monthly", new Date("2026-01-20T12:00:00Z"));
  assert(outcomes(await periodRows(u)) === "saved,frozen", "weeks 1 and 2 are logged before the change");
  const s = await accountStreak(u);
  assert(iso(s.currentPeriodStart) === "2026-01-01T00:00:00.000Z", `re-anchored to January, got ${iso(s.currentPeriodStart)}`);
  assert(iso(s.currentPeriodEnd) === "2026-02-01T00:00:00.000Z", `ends February 1, got ${iso(s.currentPeriodEnd)}`);
  assert(!s.currentPeriodSatisfied, "the new period is not saved yet");
  assert(ov.frequency === "monthly" && ov.hero?.count === 1, `monthly, count 1, got ${ov.frequency} ${ov.hero?.count}`);
}

// --- C3: a time zone change moves only the open period's end ----------------

async function westwardChange() {
  const u = await newUser("c3-west");
  await recordSave(u, `save-${randomUUID()}`, SAVE_W1);
  await setUserTimezone(u, "America/Los_Angeles", new Date("2026-01-08T12:00:00Z"));
  const [user] = await db.select().from(usersTable).where(eq(usersTable.id, u));
  assert(user.timezone === "America/Los_Angeles", `zone stored, got ${user.timezone}`);
  let s = await accountStreak(u);
  assert(iso(s.currentPeriodStart) === iso(W1), `the start stays, got ${iso(s.currentPeriodStart)}`);
  assert(iso(s.currentPeriodEnd) === "2026-01-12T08:00:00.000Z", `ends Monday 00:00 PST, got ${iso(s.currentPeriodEnd)}`);
  assert(s.currentPeriodSatisfied, "the save already made is kept");

  // Sunday evening in Los Angeles: the same local week, so no second count.
  await recordSave(u, `save-${randomUUID()}`, new Date("2026-01-12T05:00:00Z"));
  s = await accountStreak(u);
  assert(s.currentCount === 1, `same local week stays at 1, got ${s.currentCount}`);

  // Monday in Los Angeles: the next week counts.
  await recordSave(u, `save-${randomUUID()}`, new Date("2026-01-12T09:00:00Z"));
  s = await accountStreak(u);
  assert(s.currentCount === 2, `next local week advances to 2, got ${s.currentCount}`);
  const rows = await periodRows(u);
  assert(rows.length === 1 && rows[0].outcome === "saved", `one saved row, got ${outcomes(rows)}`);
  assert(iso(rows[0].periodStart) === iso(W1), "the logged week starts where it did");
  assert(iso(rows[0].periodEnd) === "2026-01-12T08:00:00.000Z", `and ends on the local boundary, got ${iso(rows[0].periodEnd)}`);
}

async function eastwardChange() {
  const u = await newUser("c3-east");
  await recordSave(u, `save-${randomUUID()}`, SAVE_W1);
  // Sunday 20:00Z is already Monday 09:00 in Auckland. The Auckland boundary
  // nearest the saved week's end (Monday 00:00 NZDT, 2026-01-11T11:00Z) has
  // passed, so the week closes as kept and the Auckland week opens.
  await setUserTimezone(u, "Pacific/Auckland", new Date("2026-01-11T20:00:00Z"));
  let s = await accountStreak(u);
  assert(iso(s.currentPeriodStart) === "2026-01-11T11:00:00.000Z", `the Auckland week opens, got ${iso(s.currentPeriodStart)}`);
  assert(iso(s.currentPeriodEnd) === "2026-01-18T11:00:00.000Z", `ends Monday 00:00 NZDT, got ${iso(s.currentPeriodEnd)}`);
  assert(!s.currentPeriodSatisfied && s.currentCount === 1, `open and still 1, got ${s.currentPeriodSatisfied} ${s.currentCount}`);
  const rows = await periodRows(u);
  assert(
    outcomes(rows) === "saved" && iso(rows[0].periodStart) === iso(W1) && iso(rows[0].periodEnd) === "2026-01-11T11:00:00.000Z",
    "the saved week keeps its start and ends on the Auckland boundary",
  );
  // So a save in the Auckland week counts.
  await recordSave(u, `save-${randomUUID()}`, new Date("2026-01-13T12:00:00Z"));
  s = await accountStreak(u);
  assert(s.currentCount === 2, `a save in the next local week counts, got ${s.currentCount}`);
}

async function settleInOldZoneFirst() {
  const u = await newUser("c3-settle");
  await recordSave(u, `save-${randomUUID()}`, SAVE_W1);
  await setUserTimezone(u, "America/Los_Angeles", new Date("2026-01-20T12:00:00Z"));
  const rows = await periodRows(u);
  assert(outcomes(rows) === "saved,frozen", `weeks 1 and 2 logged, got ${outcomes(rows)}`);
  assert(iso(rows[1].periodStart) === iso(W2) && iso(rows[1].periodEnd) === iso(W3), "week 2 keeps its UTC bounds");
  const s = await accountStreak(u);
  assert(iso(s.currentPeriodEnd) === "2026-01-26T08:00:00.000Z", `ends Monday 00:00 PST, got ${iso(s.currentPeriodEnd)}`);
}

async function sameZoneIsNoOp() {
  const u = await newUser("c3-noop");
  await recordSave(u, `save-${randomUUID()}`, SAVE_W1);
  const now = new Date("2026-01-08T12:00:00Z");
  await setUserTimezone(u, "Africa/Accra", now);
  const streakBefore = await accountStreak(u);
  const [userBefore] = await db.select().from(usersTable).where(eq(usersTable.id, u));
  await setUserTimezone(u, "Africa/Accra", now);
  const streakAfter = await accountStreak(u);
  const [userAfter] = await db.select().from(usersTable).where(eq(usersTable.id, u));
  assert(iso(streakAfter.updatedAt) === iso(streakBefore.updatedAt), "the same zone again leaves the streak alone");
  assert(iso(userAfter.updatedAt) === iso(userBefore.updatedAt), "the same zone again leaves the user alone");
}

async function badgeNotReKeyed() {
  const u = await newUser("c3-badge");
  await insertQuarterStreak(u);
  let ov = await getStreakOverview(u, new Date("2026-04-06T12:00:00Z"));
  assert(ov.badges.length === 1 && ov.badges[0].badgeKey === "2026-q2", `one badge 2026-q2 in UTC, got ${JSON.stringify(ov.badges)}`);
  await setUserTimezone(u, "America/Los_Angeles", new Date("2026-04-08T00:00:00Z"));
  const s = await accountStreak(u);
  assert(iso(s.currentPeriodEnd) === "2026-04-13T07:00:00.000Z", `ends Monday 00:00 PDT, got ${iso(s.currentPeriodEnd)}`);
  // This read rolls. In Los Angeles the milestone (Apr 1 05:00Z) is Mar 31, Q1.
  ov = await getStreakOverview(u, new Date("2026-04-13T12:00:00Z"));
  assert(ov.timezone === "America/Los_Angeles", `the overview names its zone, got ${ov.timezone}`);
  assert(ov.badges.length === 1, `still exactly one badge, got ${JSON.stringify(ov.badges)}`);
}

/**
 * The new zone's period holding the change began before the open period did, so
 * ending at its boundary would leave only its tail open (`tailEnd`). The open
 * period is not saved, so it ends at the first boundary at or after an hour
 * before its old end instead: the next settle after the tail uses no freeze and
 * keeps the count, a save in the period counts once, and the period then closes
 * as saved.
 */
async function noTailAfterChange(c: {
  label: string;
  cadence: "daily" | "weekly";
  zone: string;
  save: Date;
  changeAt: Date;
  /** Settle the closed period inside the change instead of in a read just before it. */
  settleInChange?: boolean;
  end: string;
  tailEnd: Date;
  saveAt: Date;
}) {
  const u = await newUser(c.label, c.cadence);
  await recordSave(u, `save-${randomUUID()}`, c.save);
  if (!c.settleInChange) await getStreakOverview(u, c.changeAt);
  await setUserTimezone(u, c.zone, c.changeAt);
  const s = await accountStreak(u);
  assert(!s.currentPeriodSatisfied, "the open period is not saved yet");
  assert(iso(s.currentPeriodEnd) === c.end, `ends ${c.end}, got ${iso(s.currentPeriodEnd)}`);
  const freeze = await freezeRow(u);
  const logged = (await periodRows(u)).length;

  // The next settle, an hour after the tail would have closed.
  const ov = await getStreakOverview(u, new Date(c.tailEnd.getTime() + 3_600_000));
  assert(ov.hero?.count === 1 && ov.hero.status === "active", `count 1 active, got ${JSON.stringify(ov.hero)}`);
  assert(isDeepStrictEqual(await freezeRow(u), freeze), "no freeze is used");
  assert((await periodRows(u)).length === logged, "nothing is logged");

  await recordSave(u, `save-${randomUUID()}`, c.saveAt);
  const saved = await accountStreak(u);
  assert(saved.currentCount === 2, `a save in the period counts, got ${saved.currentCount}`);
  await getStreakOverview(u, new Date(Date.parse(c.end) + 3_600_000));
  const rows = await periodRows(u);
  const last = rows[rows.length - 1];
  assert(rows.every((r) => r.outcome === "saved"), `nothing frozen or missed, got ${outcomes(rows)}`);
  assert(iso(last.periodStart) === iso(s.currentPeriodStart) && iso(last.periodEnd) === c.end, "the period closes on its bounds");
  assert((await freezeRow(u))?.usedTotal === 0, "no freeze is used");
}

// Sunday 19:00 in Los Angeles, after the UTC week rolled at Monday 00:00Z.
const weeklyWestwardSundayEvening = () =>
  noTailAfterChange({
    label: "c3-tail-week-west",
    cadence: "weekly",
    zone: "America/Los_Angeles",
    save: SAVE_W1,
    changeAt: new Date("2026-01-12T03:00:00Z"),
    end: "2026-01-19T08:00:00.000Z",
    tailEnd: new Date("2026-01-12T08:00:00Z"),
    saveAt: new Date("2026-01-14T12:00:00Z"),
  });

// 19:00 in Los Angeles, after the UTC day rolled.
const dailyWestwardEvening = () =>
  noTailAfterChange({
    label: "c3-tail-day-west",
    cadence: "daily",
    zone: "America/Los_Angeles",
    save: new Date("2026-01-11T12:00:00Z"),
    changeAt: new Date("2026-01-12T03:00:00Z"),
    end: "2026-01-13T08:00:00.000Z",
    tailEnd: new Date("2026-01-12T08:00:00Z"),
    saveAt: new Date("2026-01-12T20:00:00Z"),
  });

// Half an hour after the UTC day rolled; the Tokyo day began at 15:00Z.
const dailyEastwardAfterUtcBoundary = () =>
  noTailAfterChange({
    label: "c3-tail-day-east",
    cadence: "daily",
    zone: "Asia/Tokyo",
    save: new Date("2026-01-11T12:00:00Z"),
    changeAt: new Date("2026-01-12T00:30:00Z"),
    settleInChange: true,
    end: "2026-01-13T15:00:00.000Z",
    tailEnd: new Date("2026-01-12T15:00:00Z"),
    saveAt: new Date("2026-01-13T03:00:00Z"),
  });

// --- Lead ruling B-SAFE-1 (revised): the worked examples --------------------

const HOUR = 3_600_000;
const DAY = 24 * HOUR;
/** A save in the UTC week before W1: the change settles that week, and W1 opens not saved. */
const PREV_SAVE = new Date("2025-12-29T12:00:00Z");
const WED_W1 = new Date("2026-01-07T12:00:00Z");

type ZoneCase = {
  label: string;
  cadence?: Frequency;
  /** The zone before the change (UTC unless given). */
  from?: string;
  zone: string;
  saves: Date[];
  changeAt: Date;
  /** The open period's home end: its end in the old zone, after any settle there. */
  oldEnd: string;
  start: string;
  end: string;
  /** Whether the open period is saved right after the change. */
  saved: boolean;
  count: number;
  /** Outcomes logged when the change returns. */
  logged: string;
  /** Set when the change closes the saved period at once: where it ends. */
  closedEnd?: string;
  /** In the next local period when the open one is saved, else inside it. */
  nextSave: Date;
};

/**
 * One worked example. The person saves at `saves` in the old zone, then changes
 * zone. The home end is read back first: the open period's end, or, when it has
 * closed, the old zone's next period end (the change settles there first).
 * Right after the change: the open period's bounds, whether it is saved, the
 * count, what was logged (a period closed at once on its bounds), status active
 * and no freeze used. A period not saved yet never ends more than an hour before
 * its home end, and the home end passing closes nothing (G1); in a saved one a
 * second save before the end adds nothing (G3). Then the next save adds exactly
 * one step, and the period closes as saved on its bounds (G2, G3).
 */
async function zoneRule(c: ZoneCase): Promise<string> {
  const cadence = c.cadence ?? "weekly";
  const u = await newUser(c.label, cadence, c.from);
  for (const at of c.saves) await recordSave(u, `save-${randomUUID()}`, at);
  const label = `${c.label}:`;
  const before = await accountStreak(u);
  const homeEnd =
    before.currentPeriodEnd.getTime() > c.changeAt.getTime()
      ? before.currentPeriodEnd.getTime()
      : localPeriod(c.changeAt, cadence, c.from ?? "UTC").end;
  assert(homeEnd === Date.parse(c.oldEnd), `${label} the home end is ${c.oldEnd}, got ${iso(new Date(homeEnd))}`);
  await setUserTimezone(u, c.zone, c.changeAt);
  const s = await accountStreak(u);
  assert(iso(s.currentPeriodStart) === c.start, `${label} starts ${c.start}, got ${iso(s.currentPeriodStart)}`);
  assert(iso(s.currentPeriodEnd) === c.end, `${label} ends ${c.end}, got ${iso(s.currentPeriodEnd)}`);
  assert(s.currentPeriodSatisfied === c.saved, `${label} saved ${c.saved}, got ${s.currentPeriodSatisfied}`);
  assert(s.currentCount === c.count && s.status === "active", `${label} ${c.count} active, got ${s.currentCount} ${s.status}`);
  assert(outcomes(await periodRows(u)) === c.logged, `${label} logged "${c.logged}", got "${outcomes(await periodRows(u))}"`);
  assert(((await freezeRow(u))?.usedTotal ?? 0) === 0, `${label} no freeze is used`);
  if (c.closedEnd) {
    const closed = (await periodRows(u)).find((r) => iso(r.periodStart) === iso(before.currentPeriodStart));
    assert(
      closed?.outcome === "saved" && iso(closed.periodEnd) === c.closedEnd && c.start === c.closedEnd,
      `${label} closed as kept from ${iso(before.currentPeriodStart)} to ${c.closedEnd}, got ${JSON.stringify(closed)}`,
    );
  }

  const end = Date.parse(c.end);
  if (c.saved) {
    await recordSave(u, `save-${randomUUID()}`, new Date(end - 30 * 60_000));
    assert((await accountStreak(u)).currentCount === c.count, `${label} a second save before the end adds nothing`);
  } else {
    assert(end >= homeEnd - HOUR, `${label} at most an hour shorter than the home end`);
    if (end > homeEnd + HOUR) {
      const ov = await getStreakOverview(u, new Date(homeEnd + HOUR));
      const hero = JSON.stringify(ov.hero);
      assert(ov.hero?.count === c.count && ov.hero.status === "active", `${label} the home end closes nothing, got ${hero}`);
      assert(outcomes(await periodRows(u)) === c.logged, `${label} nothing is logged at the home end`);
    }
  }

  await recordSave(u, `save-${randomUUID()}`, c.nextSave);
  assert((await accountStreak(u)).currentCount === c.count + 1, `${label} the next save adds one step`);
  const ov = await getStreakOverview(u, new Date(Math.max(end, c.nextSave.getTime()) + HOUR));
  assert(ov.hero?.count === c.count + 1 && ov.hero.status === "active", `${label} ${c.count + 1} active, got ${JSON.stringify(ov.hero)}`);
  const rows = await periodRows(u);
  const closed = rows.find((r) => iso(r.periodStart) === c.start);
  assert(
    closed && iso(closed.periodEnd) === c.end && closed.outcome === "saved",
    `${label} closes as saved on its bounds, got ${JSON.stringify(closed)}`,
  );
  assert(rows.every((r) => r.outcome === "saved"), `${label} nothing frozen or missed, got ${outcomes(rows)}`);
  assert(((await freezeRow(u))?.usedTotal ?? 0) === 0, `${label} no freeze is used`);
  return u;
}

/** Example 10: monthly, Lagos, mid-month. A month of `days` days ends at 23:00Z on its last day. */
function monthlyLagos(y: number, m: number, days: number): ZoneCase[] {
  const d = (day: number, h = 0, min = 0) => new Date(Date.UTC(y, m - 1, day, h, min));
  const base = {
    cadence: "monthly" as const,
    zone: "Africa/Lagos",
    changeAt: d(15, 12),
    oldEnd: iso(d(days + 1)),
    start: iso(d(1)),
    end: iso(d(days, 23)),
  };
  return [
    { ...base, label: `r2-10-${y}-${m}-saved`, saves: [d(10, 12)], saved: true, count: 1, logged: "", nextSave: d(days, 23, 30) },
    {
      ...base, label: `r2-10-${y}-${m}-open`, saves: [new Date(Date.UTC(y, m - 2, 10, 12))],
      saved: false, count: 1, logged: "saved", nextSave: d(20, 12),
    },
  ];
}

/** Example 11: weekly, on the Wednesday, in a zone off the whole hour or far from UTC. */
function oddZone(tag: string, zone: string, savedEnd: string, openEnd: string): ZoneCase[] {
  const base = { zone, changeAt: WED_W1, oldEnd: iso(W2), start: iso(W1) };
  return [
    {
      ...base, label: `r2-11-${tag}-saved`, saves: [SAVE_W1], end: savedEnd, saved: true, count: 1, logged: "",
      nextSave: new Date(Date.parse(savedEnd) + HOUR),
    },
    {
      ...base, label: `r2-11-${tag}-open`, saves: [PREV_SAVE], end: openEnd, saved: false, count: 1, logged: "saved",
      nextSave: new Date("2026-01-09T12:00:00Z"),
    },
  ];
}

/** Example 12: weekly, on the Wednesday of a UTC week whose Sunday has a DST change. */
function dstWeek(tag: string, zone: string, monday: string, end: string): ZoneCase[] {
  const mon = Date.parse(monday);
  const at = (ms: number) => new Date(mon + ms);
  const base = { zone, changeAt: at(2 * DAY + 12 * HOUR), oldEnd: iso(at(7 * DAY)), start: iso(at(0)), end };
  return [
    {
      ...base, label: `r2-12-${tag}-saved`, saves: [at(12 * HOUR)], saved: true, count: 1, logged: "",
      nextSave: new Date(Date.parse(end) + HOUR),
    },
    {
      ...base, label: `r2-12-${tag}-open`, saves: [at(-7 * DAY + 12 * HOUR)], saved: false, count: 1, logged: "saved",
      nextSave: at(3 * DAY + 12 * HOUR),
    },
  ];
}

const ZONE_CASES: ZoneCase[] = [
  // 1 and 2: Lagos (+1) on the Wednesday. Saved: a save in the next local week (Monday 00:30 there) counts.
  {
    label: "r2-01-lagos-saved", zone: "Africa/Lagos", saves: [SAVE_W1], changeAt: WED_W1, oldEnd: iso(W2),
    start: iso(W1), end: "2026-01-11T23:00:00.000Z", saved: true, count: 1, logged: "",
    nextSave: new Date("2026-01-11T23:30:00Z"),
  },
  {
    label: "r2-02-lagos-open", zone: "Africa/Lagos", saves: [PREV_SAVE], changeAt: WED_W1, oldEnd: iso(W2),
    start: iso(W1), end: "2026-01-11T23:00:00.000Z", saved: false, count: 1, logged: "saved",
    nextSave: new Date("2026-01-09T12:00:00Z"),
  },
  // The same in the old week's last hour (Sunday 23:30Z, Monday 00:30 in Lagos). Saved (a second save at
  // 22:30Z adds nothing): Sunday 23:00Z has passed, so the week closes as kept now. Not saved: that boundary
  // has passed, so the first one after now.
  {
    label: "r2-01-lagos-saved-last-hour", zone: "Africa/Lagos", saves: [SAVE_W1, new Date("2026-01-11T22:30:00Z")],
    changeAt: new Date("2026-01-11T23:30:00Z"), oldEnd: iso(W2),
    start: "2026-01-11T23:00:00.000Z", end: "2026-01-18T23:00:00.000Z", saved: false, count: 1, logged: "saved",
    closedEnd: "2026-01-11T23:00:00.000Z", nextSave: new Date("2026-01-11T23:45:00Z"),
  },
  {
    label: "r2-02-lagos-open-last-hour", zone: "Africa/Lagos", saves: [PREV_SAVE],
    changeAt: new Date("2026-01-11T23:30:00Z"), oldEnd: iso(W2),
    start: iso(W1), end: "2026-01-18T23:00:00.000Z", saved: false, count: 1, logged: "saved",
    nextSave: new Date("2026-01-14T12:00:00Z"),
  },
  // 3 and 4: Nairobi (+3). Saved: a save on Monday 01:00 there counts. Not saved: never 3 hours shorter.
  {
    label: "r2-03-nairobi-saved", zone: "Africa/Nairobi", saves: [SAVE_W1], changeAt: WED_W1, oldEnd: iso(W2),
    start: iso(W1), end: "2026-01-11T21:00:00.000Z", saved: true, count: 1, logged: "",
    nextSave: new Date("2026-01-11T22:00:00Z"),
  },
  {
    label: "r2-04-nairobi-open", zone: "Africa/Nairobi", saves: [PREV_SAVE], changeAt: WED_W1, oldEnd: iso(W2),
    start: iso(W1), end: "2026-01-18T21:00:00.000Z", saved: false, count: 1, logged: "saved",
    nextSave: new Date("2026-01-14T12:00:00Z"),
  },
  // 5: Nairobi on Sunday 22:00Z (Monday 01:00 there), saved (a second save at 20:30Z adds nothing): Sunday
  // 21:00Z has passed, so the week closes as kept now and the Nairobi week opens; the count is unchanged and
  // a save now counts.
  {
    label: "r2-05-nairobi-closes", zone: "Africa/Nairobi", saves: [SAVE_W1, new Date("2026-01-11T20:30:00Z")],
    changeAt: new Date("2026-01-11T22:00:00Z"), oldEnd: iso(W2),
    start: "2026-01-11T21:00:00.000Z", end: "2026-01-18T21:00:00.000Z", saved: false, count: 1, logged: "saved",
    closedEnd: "2026-01-11T21:00:00.000Z", nextSave: new Date("2026-01-11T22:30:00Z"),
  },
  // 6: New York on Monday 01:00Z, after the UTC week rolled, not saved: next Monday, never this one
  // (EDT, Sunday 21:00 there, and EST).
  {
    label: "r2-06-new-york-open-edt", zone: "America/New_York", saves: [new Date("2026-06-01T12:00:00Z")],
    changeAt: new Date("2026-06-08T01:00:00Z"), oldEnd: "2026-06-15T00:00:00.000Z",
    start: "2026-06-08T00:00:00.000Z", end: "2026-06-15T04:00:00.000Z", saved: false, count: 1, logged: "saved",
    nextSave: new Date("2026-06-10T12:00:00Z"),
  },
  {
    label: "r2-06-new-york-open-est", zone: "America/New_York", saves: [SAVE_W1],
    changeAt: new Date("2026-01-12T01:00:00Z"), oldEnd: iso(W3),
    start: iso(W2), end: "2026-01-19T05:00:00.000Z", saved: false, count: 1, logged: "saved",
    nextSave: new Date("2026-01-14T12:00:00Z"),
  },
  // 7: the same, saved by a save at 00:30Z: the boundary nearest the old end; the next local week's save counts.
  {
    label: "r2-07-new-york-saved", zone: "America/New_York",
    saves: [new Date("2026-06-01T12:00:00Z"), new Date("2026-06-08T00:30:00Z")],
    changeAt: new Date("2026-06-08T01:00:00Z"), oldEnd: "2026-06-15T00:00:00.000Z",
    start: "2026-06-08T00:00:00.000Z", end: "2026-06-15T04:00:00.000Z", saved: true, count: 2, logged: "saved",
    nextSave: new Date("2026-06-15T05:00:00Z"),
  },
  {
    label: "r2-07-new-york-saved-est", zone: "America/New_York", saves: [SAVE_W1, new Date("2026-01-12T00:30:00Z")],
    changeAt: new Date("2026-01-12T01:00:00Z"), oldEnd: iso(W3),
    start: iso(W2), end: "2026-01-19T05:00:00.000Z", saved: true, count: 2, logged: "saved",
    nextSave: new Date("2026-01-19T06:00:00Z"),
  },
  // 8: daily, New York, 01:00Z (the evening before there): tomorrow's local midnight, never today's 05:00Z.
  {
    label: "r2-08-daily-new-york-open", cadence: "daily", zone: "America/New_York",
    saves: [new Date("2026-01-11T12:00:00Z")], changeAt: new Date("2026-01-12T01:00:00Z"),
    oldEnd: "2026-01-13T00:00:00.000Z",
    start: iso(W2), end: "2026-01-13T05:00:00.000Z", saved: false, count: 1, logged: "saved",
    nextSave: new Date("2026-01-12T20:00:00Z"),
  },
  {
    label: "r2-08-daily-new-york-saved", cadence: "daily", zone: "America/New_York",
    saves: [new Date("2026-01-11T12:00:00Z"), new Date("2026-01-12T00:30:00Z")],
    changeAt: new Date("2026-01-12T01:00:00Z"), oldEnd: "2026-01-13T00:00:00.000Z",
    start: iso(W2), end: "2026-01-13T05:00:00.000Z", saved: true, count: 2, logged: "saved",
    nextSave: new Date("2026-01-13T06:00:00Z"),
  },
  // 9: daily, Nairobi, 00:30Z. Saved: 21:00Z today, and a save at 22:00Z (the next local day) counts.
  // Not saved: 21:00Z tomorrow.
  {
    label: "r2-09-daily-nairobi-saved", cadence: "daily", zone: "Africa/Nairobi",
    saves: [new Date("2026-01-11T12:00:00Z"), new Date("2026-01-12T00:10:00Z")],
    changeAt: new Date("2026-01-12T00:30:00Z"), oldEnd: "2026-01-13T00:00:00.000Z",
    start: iso(W2), end: "2026-01-12T21:00:00.000Z", saved: true, count: 2, logged: "saved",
    nextSave: new Date("2026-01-12T22:00:00Z"),
  },
  {
    label: "r2-09-daily-nairobi-open", cadence: "daily", zone: "Africa/Nairobi",
    saves: [new Date("2026-01-11T12:00:00Z")], changeAt: new Date("2026-01-12T00:30:00Z"),
    oldEnd: "2026-01-13T00:00:00.000Z",
    start: iso(W2), end: "2026-01-13T21:00:00.000Z", saved: false, count: 1, logged: "saved",
    nextSave: new Date("2026-01-13T12:00:00Z"),
  },
  // A tie goes to the later boundary: daily, Tarawa (+12), the old end exactly between two midnights there.
  {
    label: "r2-tie-tarawa-saved", cadence: "daily", zone: "Pacific/Tarawa",
    saves: [new Date("2026-01-11T12:00:00Z"), new Date("2026-01-12T01:00:00Z")],
    changeAt: new Date("2026-01-12T02:00:00Z"), oldEnd: "2026-01-13T00:00:00.000Z",
    start: iso(W2), end: "2026-01-13T12:00:00.000Z", saved: true, count: 2, logged: "saved",
    nextSave: new Date("2026-01-13T13:00:00Z"),
  },
  // 10: monthly, Lagos, months of 31, 28, 30 and 29 days.
  ...monthlyLagos(2026, 1, 31),
  ...monthlyLagos(2026, 2, 28),
  ...monthlyLagos(2026, 4, 30),
  ...monthlyLagos(2028, 2, 29),
  // 11: Monday 00:00 local in each zone (in January Chatham is on +13:45 and St John's on -3:30).
  ...oddZone("kolkata", "Asia/Kolkata", "2026-01-11T18:30:00.000Z", "2026-01-18T18:30:00.000Z"),
  ...oddZone("kathmandu", "Asia/Kathmandu", "2026-01-11T18:15:00.000Z", "2026-01-18T18:15:00.000Z"),
  ...oddZone("st-johns", "America/St_Johns", "2026-01-12T03:30:00.000Z", "2026-01-12T03:30:00.000Z"),
  ...oddZone("chatham", "Pacific/Chatham", "2026-01-11T10:15:00.000Z", "2026-01-18T10:15:00.000Z"),
  ...oddZone("kiritimati", "Pacific/Kiritimati", "2026-01-11T10:00:00.000Z", "2026-01-18T10:00:00.000Z"),
  ...oddZone("pago-pago", "Pacific/Pago_Pago", "2026-01-12T11:00:00.000Z", "2026-01-12T11:00:00.000Z"),
  // Chatham on +12:45 in July: the UTC week of Monday July 6, changed on the Wednesday.
  {
    label: "r2-11-chatham-july-saved", zone: "Pacific/Chatham", saves: [new Date("2026-07-06T12:00:00Z")],
    changeAt: new Date("2026-07-08T12:00:00Z"), oldEnd: "2026-07-13T00:00:00.000Z",
    start: "2026-07-06T00:00:00.000Z", end: "2026-07-12T11:15:00.000Z", saved: true, count: 1, logged: "",
    nextSave: new Date("2026-07-12T12:15:00Z"),
  },
  {
    label: "r2-11-chatham-july-open", zone: "Pacific/Chatham", saves: [new Date("2026-06-29T12:00:00Z")],
    changeAt: new Date("2026-07-08T12:00:00Z"), oldEnd: "2026-07-13T00:00:00.000Z",
    start: "2026-07-06T00:00:00.000Z", end: "2026-07-19T11:15:00.000Z", saved: false, count: 1, logged: "saved",
    nextSave: new Date("2026-07-10T12:00:00Z"),
  },
  // 12: London's summer time starts on March 29 and ends on October 25; New York's on March 8 and November 1.
  ...dstWeek("london-march", "Europe/London", "2026-03-23T00:00:00Z", "2026-03-29T23:00:00.000Z"),
  ...dstWeek("london-october", "Europe/London", "2026-10-19T00:00:00Z", "2026-10-26T00:00:00.000Z"),
  ...dstWeek("new-york-march", "America/New_York", "2026-03-02T00:00:00Z", "2026-03-09T04:00:00.000Z"),
  ...dstWeek("new-york-november", "America/New_York", "2026-10-26T00:00:00Z", "2026-11-02T05:00:00.000Z"),
  // R1: daily, to zones whose DST jump skips local midnight. Havana's March 8 starts at 05:00Z (01:00 CDT),
  // March 9 at 04:00Z; Azores' March 29 at 01:00Z; Santiago's September 6 at 04:00Z and September 7 at 03:00Z.
  {
    label: "r3-r1-havana-open", cadence: "daily", zone: "America/Havana", saves: [new Date("2026-03-07T12:00:00Z")],
    changeAt: new Date("2026-03-08T00:30:00Z"), oldEnd: "2026-03-09T00:00:00.000Z",
    start: "2026-03-08T00:00:00.000Z", end: "2026-03-09T04:00:00.000Z", saved: false, count: 1, logged: "saved",
    nextSave: new Date("2026-03-08T15:00:00Z"),
  },
  {
    label: "r3-r1-havana-open-0430", cadence: "daily", zone: "America/Havana", saves: [new Date("2026-03-07T12:00:00Z")],
    changeAt: new Date("2026-03-08T04:30:00Z"), oldEnd: "2026-03-09T00:00:00.000Z",
    start: "2026-03-08T00:00:00.000Z", end: "2026-03-09T04:00:00.000Z", saved: false, count: 1, logged: "saved",
    nextSave: new Date("2026-03-08T15:00:00Z"),
  },
  {
    label: "r3-r1-havana-saved-0430", cadence: "daily", zone: "America/Havana",
    saves: [new Date("2026-03-07T12:00:00Z"), new Date("2026-03-08T01:00:00Z")],
    changeAt: new Date("2026-03-08T04:30:00Z"), oldEnd: "2026-03-09T00:00:00.000Z",
    start: "2026-03-08T00:00:00.000Z", end: "2026-03-09T04:00:00.000Z", saved: true, count: 2, logged: "saved",
    nextSave: new Date("2026-03-09T05:00:00Z"),
  },
  {
    label: "r3-r1-azores-open", cadence: "daily", zone: "Atlantic/Azores", saves: [new Date("2026-03-27T12:00:00Z")],
    changeAt: new Date("2026-03-28T12:00:00Z"), oldEnd: "2026-03-29T00:00:00.000Z",
    start: "2026-03-28T00:00:00.000Z", end: "2026-03-29T01:00:00.000Z", saved: false, count: 1, logged: "saved",
    nextSave: new Date("2026-03-28T18:00:00Z"),
  },
  {
    label: "r3-r1-azores-saved", cadence: "daily", zone: "Atlantic/Azores",
    saves: [new Date("2026-03-27T12:00:00Z"), new Date("2026-03-28T06:00:00Z")],
    changeAt: new Date("2026-03-28T12:00:00Z"), oldEnd: "2026-03-29T00:00:00.000Z",
    start: "2026-03-28T00:00:00.000Z", end: "2026-03-29T01:00:00.000Z", saved: true, count: 2, logged: "saved",
    nextSave: new Date("2026-03-29T02:00:00Z"),
  },
  {
    label: "r3-r1-santiago-open", cadence: "daily", zone: "America/Santiago", saves: [new Date("2026-09-05T12:00:00Z")],
    changeAt: new Date("2026-09-06T01:00:00Z"), oldEnd: "2026-09-07T00:00:00.000Z",
    start: "2026-09-06T00:00:00.000Z", end: "2026-09-07T03:00:00.000Z", saved: false, count: 1, logged: "saved",
    nextSave: new Date("2026-09-06T15:00:00Z"),
  },
  // R3: a change in the open period's last hour, to a zone whose boundary falls in that hour (here a DST
  // hour). The first boundary at or after an hour before the home end has passed, so a period not saved yet
  // ends at the first boundary after now: it holds two whole new-zone periods, and ends less than one
  // period after the change.
  {
    label: "r3-r3-utc-london-weekly", zone: "Europe/London", saves: [new Date("2026-03-16T12:00:00Z")],
    changeAt: new Date("2026-03-29T23:30:00Z"), oldEnd: "2026-03-30T00:00:00.000Z",
    start: "2026-03-23T00:00:00.000Z", end: "2026-04-05T23:00:00.000Z", saved: false, count: 1, logged: "saved",
    nextSave: new Date("2026-04-01T12:00:00Z"),
  },
  {
    label: "r3-r3-london-lagos-daily", cadence: "daily", from: "Europe/London", zone: "Africa/Lagos",
    saves: [new Date("2026-10-24T12:00:00Z")], changeAt: new Date("2026-10-25T23:30:00Z"), oldEnd: "2026-10-26T00:00:00.000Z",
    start: "2026-10-24T23:00:00.000Z", end: "2026-10-26T23:00:00.000Z", saved: false, count: 1, logged: "saved",
    nextSave: new Date("2026-10-26T12:00:00Z"),
  },
  {
    label: "r3-r3-st-johns-sao-paulo-daily", cadence: "daily", from: "America/St_Johns", zone: "America/Sao_Paulo",
    saves: [new Date("2026-10-31T15:00:00Z")], changeAt: new Date("2026-11-02T03:15:00Z"), oldEnd: "2026-11-02T03:30:00.000Z",
    start: "2026-11-01T02:30:00.000Z", end: "2026-11-03T03:00:00.000Z", saved: false, count: 1, logged: "saved",
    nextSave: new Date("2026-11-02T15:00:00Z"),
  },
];

/**
 * Example 13: London, then Nairobi, then New York within one period; then New York again, a no-op. Each change
 * is measured against the home end, the UTC week's end (R2): not saved, New York ends at 06-08T04:00Z, where
 * one change from UTC would (round 2 gave 06-15T04:00Z, from Nairobi's stretched end).
 */
async function zoneChangesWithinOnePeriod(saved: boolean) {
  const u = await newUser(`r2-13-${saved ? "saved" : "open"}`);
  await recordSave(u, `save-${randomUUID()}`, new Date("2026-05-25T12:00:00Z"));
  if (saved) await recordSave(u, `save-${randomUUID()}`, new Date("2026-06-01T12:00:00Z"));
  else await getStreakOverview(u, new Date("2026-06-01T12:00:00Z"));
  const count = saved ? 2 : 1;
  const homeEnd = (await accountStreak(u)).currentPeriodEnd.getTime();
  assert(homeEnd === Date.parse("2026-06-08T00:00:00Z"), `the home end is the UTC week's, got ${iso(new Date(homeEnd))}`);
  const steps: [zone: string, at: string, end: string][] = [
    ["Europe/London", "2026-06-02T12:00:00Z", "2026-06-07T23:00:00.000Z"],
    ["Africa/Nairobi", "2026-06-03T12:00:00Z", saved ? "2026-06-07T21:00:00.000Z" : "2026-06-14T21:00:00.000Z"],
    ["America/New_York", "2026-06-04T12:00:00Z", "2026-06-08T04:00:00.000Z"],
  ];
  for (const [zone, at, end] of steps) {
    await setUserTimezone(u, zone, new Date(at));
    const s = await accountStreak(u);
    assert(iso(s.currentPeriodStart) === "2026-06-01T00:00:00.000Z", `${zone}: the start stays, got ${iso(s.currentPeriodStart)}`);
    assert(iso(s.currentPeriodEnd) === end, `${zone}: ends ${end}, got ${iso(s.currentPeriodEnd)}`);
    assert(s.currentPeriodSatisfied === saved && s.currentCount === count && s.status === "active", `${zone}: unchanged otherwise`);
    if (!saved) assert(s.currentPeriodEnd.getTime() >= homeEnd - HOUR, `${zone}: at most an hour short of the home end`);
  }
  const end = Date.parse(steps[2][2]);

  const streakBefore = await accountStreak(u);
  const [userBefore] = await db.select().from(usersTable).where(eq(usersTable.id, u));
  await setUserTimezone(u, "America/New_York", new Date("2026-06-05T12:00:00Z"));
  const [userAfter] = await db.select().from(usersTable).where(eq(usersTable.id, u));
  assert(iso((await accountStreak(u)).updatedAt) === iso(streakBefore.updatedAt), "the same zone again leaves the streak alone");
  assert(iso(userAfter.updatedAt) === iso(userBefore.updatedAt), "the same zone again leaves the user alone");

  if (saved) {
    // A save before the end stays in the saved period (R10).
    await recordSave(u, `save-${randomUUID()}`, new Date(end - HOUR));
    assert((await accountStreak(u)).currentCount === count, "a save before the end adds nothing");
  } else {
    // The UTC week's end passing closes nothing.
    const ov = await getStreakOverview(u, new Date("2026-06-08T01:00:00Z"));
    assert(ov.hero?.count === 1 && ov.hero.status === "active", `still 1 active, got ${JSON.stringify(ov.hero)}`);
  }
  await recordSave(u, `save-${randomUUID()}`, saved ? new Date(end + HOUR) : new Date("2026-06-08T02:00:00Z"));
  assert((await accountStreak(u)).currentCount === count + 1, "the next save adds one step");
  await getStreakOverview(u, new Date(end + 2 * HOUR));
  const rows = await periodRows(u);
  assert(outcomes(rows) === "saved,saved", `both periods saved, got ${outcomes(rows)}`);
  assert(iso(rows[1].periodStart) === "2026-06-01T00:00:00.000Z" && iso(rows[1].periodEnd) === steps[2][2], "the period closes on its bounds");
  assert(((await freezeRow(u))?.usedTotal ?? 0) === 0, "no freeze is used");
}

// --- Lead rulings, round 3 -----------------------------------------------------

type PathCase = {
  label: string;
  cadence?: Frequency;
  from: string;
  /** Saves in the home zone; a read at `readAt` then settles what has closed, so the open period is read back. */
  saves: Date[];
  readAt: Date;
  /** The open period before the first change: its start and its home end. */
  start: string;
  homeEnd: string;
  saved: boolean;
  count: number;
  /** Each change, and the end it gives. */
  steps: [zone: string, at: string, end: string][];
  /** Saves after the last change, each with the count it gives. */
  after: [at: string, count: number][];
};

/**
 * R2: a path of changes inside one period. The end depends only on the home
 * end, so a chain ends where one change from the home zone at the time of the
 * last change would, and a round trip restores the period. After each change:
 * the start stays, the end, saved or not and the count; a period not saved yet
 * never ends more than an hour before its home end (G1). Then the saves give
 * their counts, and the period closes as saved on its bounds with no freeze.
 */
async function zonePath(c: PathCase) {
  const cadence = c.cadence ?? "weekly";
  const u = await newUser(c.label, cadence, c.from);
  for (const at of c.saves) await recordSave(u, `save-${randomUUID()}`, at);
  await getStreakOverview(u, c.readAt);
  const label = `${c.label}:`;
  const before = await accountStreak(u);
  assert(
    iso(before.currentPeriodStart) === c.start && iso(before.currentPeriodEnd) === c.homeEnd,
    `${label} opens ${c.start} to ${c.homeEnd}, got ${iso(before.currentPeriodStart)} to ${iso(before.currentPeriodEnd)}`,
  );
  const homeEnd = Date.parse(c.homeEnd);
  for (const [zone, at, end] of c.steps) {
    await setUserTimezone(u, zone, new Date(at));
    const s = await accountStreak(u);
    const tag = `${label} ${zone} at ${at}:`;
    assert(iso(s.currentPeriodStart) === c.start, `${tag} the start stays, got ${iso(s.currentPeriodStart)}`);
    assert(iso(s.currentPeriodEnd) === end, `${tag} ends ${end}, got ${iso(s.currentPeriodEnd)}`);
    assert(
      s.currentPeriodSatisfied === c.saved && s.currentCount === c.count && s.status === "active",
      `${tag} ${c.saved} ${c.count} active, got ${s.currentPeriodSatisfied} ${s.currentCount} ${s.status}`,
    );
    if (!c.saved) assert(s.currentPeriodEnd.getTime() >= homeEnd - HOUR, `${tag} at most an hour short of the home end`);
  }
  for (const [at, count] of c.after) {
    await recordSave(u, `save-${randomUUID()}`, new Date(at));
    const got = (await accountStreak(u)).currentCount;
    assert(got === count, `${label} a save at ${at} gives ${count}, got ${got}`);
  }
  const end = c.steps[c.steps.length - 1][2];
  await getStreakOverview(u, new Date(Math.max(Date.parse(end), Date.parse(c.after[c.after.length - 1][0])) + HOUR));
  const rows = await periodRows(u);
  const closed = rows.find((r) => iso(r.periodStart) === c.start);
  assert(closed?.outcome === "saved" && iso(closed.periodEnd) === end, `${label} closes as saved on its bounds, got ${JSON.stringify(closed)}`);
  assert(rows.every((r) => r.outcome === "saved"), `${label} nothing frozen or missed, got ${outcomes(rows)}`);
  assert(((await freezeRow(u))?.usedTotal ?? 0) === 0, `${label} no freeze is used`);
}

const PATH_CASES: PathCase[] = [
  // (b) Round trips restore the period. Nairobi, London, Nairobi, weekly, not saved (CAL-3 R1): saves in the
  // Nairobi weeks of January 12 and 19 each count.
  {
    label: "r3-r2-trip-nairobi-london-weekly-open", from: "Africa/Nairobi", saves: [new Date("2026-01-07T12:00:00Z")],
    readAt: new Date("2026-01-12T12:00:00Z"), start: "2026-01-11T21:00:00.000Z", homeEnd: "2026-01-18T21:00:00.000Z",
    saved: false, count: 1,
    steps: [
      ["Europe/London", "2026-01-13T12:00:00Z", "2026-01-19T00:00:00.000Z"],
      ["Africa/Nairobi", "2026-01-16T12:00:00Z", "2026-01-18T21:00:00.000Z"],
    ],
    after: [["2026-01-17T12:00:00Z", 2], ["2026-01-21T12:00:00Z", 3]],
  },
  // UTC, Fiji, UTC, daily, saved: two 12-hour ties; the UTC day is restored, so a save on January 13 counts.
  {
    label: "r3-r2-trip-utc-fiji-daily-saved", cadence: "daily", from: "UTC",
    saves: [new Date("2026-01-11T12:00:00Z"), new Date("2026-01-12T01:00:00Z")], readAt: new Date("2026-01-12T01:30:00Z"),
    start: iso(W2), homeEnd: "2026-01-13T00:00:00.000Z", saved: true, count: 2,
    steps: [
      ["Pacific/Fiji", "2026-01-12T08:00:00Z", "2026-01-13T12:00:00.000Z"],
      ["UTC", "2026-01-12T10:00:00Z", "2026-01-13T00:00:00.000Z"],
    ],
    after: [["2026-01-12T20:00:00Z", 2], ["2026-01-13T06:00:00Z", 3]],
  },
  // UTC, New York, UTC, weekly, not saved (west), and UTC, Nairobi, UTC (east): W1 and W2 each count.
  {
    label: "r3-r2-trip-utc-new-york-weekly-open", from: "UTC", saves: [PREV_SAVE], readAt: new Date("2026-01-05T12:00:00Z"),
    start: iso(W1), homeEnd: iso(W2), saved: false, count: 1,
    steps: [
      ["America/New_York", "2026-01-07T12:00:00Z", "2026-01-12T05:00:00.000Z"],
      ["UTC", "2026-01-09T12:00:00Z", iso(W2)],
    ],
    after: [["2026-01-10T12:00:00Z", 2], ["2026-01-14T12:00:00Z", 3]],
  },
  {
    label: "r3-r2-trip-utc-nairobi-weekly-open", from: "UTC", saves: [PREV_SAVE], readAt: new Date("2026-01-05T12:00:00Z"),
    start: iso(W1), homeEnd: iso(W2), saved: false, count: 1,
    steps: [
      ["Africa/Nairobi", "2026-01-07T12:00:00Z", "2026-01-18T21:00:00.000Z"],
      ["UTC", "2026-01-09T12:00:00Z", iso(W2)],
    ],
    after: [["2026-01-10T12:00:00Z", 2], ["2026-01-14T12:00:00Z", 3]],
  },
  // The same trip, saved: also restored.
  {
    label: "r3-r2-trip-utc-nairobi-weekly-saved", from: "UTC", saves: [SAVE_W1], readAt: new Date("2026-01-05T13:00:00Z"),
    start: iso(W1), homeEnd: iso(W2), saved: true, count: 1,
    steps: [
      ["Africa/Nairobi", "2026-01-07T12:00:00Z", "2026-01-11T21:00:00.000Z"],
      ["UTC", "2026-01-09T12:00:00Z", iso(W2)],
    ],
    after: [["2026-01-11T22:00:00Z", 1], ["2026-01-12T01:00:00Z", 2]],
  },
  // Monthly, Nairobi, London, Nairobi, not saved (CAL-3 R7): January and February stay apart.
  {
    label: "r3-r2-trip-nairobi-london-monthly-open", cadence: "monthly", from: "Africa/Nairobi",
    saves: [new Date("2025-12-10T12:00:00Z")], readAt: new Date("2026-01-05T12:00:00Z"),
    start: "2025-12-31T21:00:00.000Z", homeEnd: "2026-01-31T21:00:00.000Z", saved: false, count: 1,
    steps: [
      ["Europe/London", "2026-01-10T12:00:00Z", "2026-02-01T00:00:00.000Z"],
      ["Africa/Nairobi", "2026-01-20T12:00:00Z", "2026-01-31T21:00:00.000Z"],
    ],
    after: [["2026-01-25T12:00:00Z", 2], ["2026-02-10T12:00:00Z", 3]],
  },
  // (c) Chains end where one change from the home zone would. Accra, Lagos, Johannesburg, weekly (CAL-2): as
  // Accra to Johannesburg directly, 01-25T22:00Z; a save at 01-18T22:30Z (Monday 00:30 there) counts.
  {
    label: "r3-r2-chain-accra-lagos-johannesburg", from: "Africa/Accra", saves: [new Date("2026-01-05T12:00:00Z")],
    readAt: new Date("2026-01-12T12:00:00Z"), start: iso(W2), homeEnd: iso(W3), saved: false, count: 1,
    steps: [
      ["Africa/Lagos", "2026-01-13T12:00:00Z", "2026-01-18T23:00:00.000Z"],
      ["Africa/Johannesburg", "2026-01-15T12:00:00Z", "2026-01-25T22:00:00.000Z"],
    ],
    after: [["2026-01-18T22:30:00Z", 2]],
  },
  // UTC, Lagos, Johannesburg, Nairobi (F9): as UTC to Nairobi directly (example 4), 01-18T21:00Z.
  {
    label: "r3-r2-chain-utc-lagos-johannesburg-nairobi", from: "UTC", saves: [PREV_SAVE], readAt: new Date("2026-01-05T12:00:00Z"),
    start: iso(W1), homeEnd: iso(W2), saved: false, count: 1,
    steps: [
      ["Africa/Lagos", "2026-01-07T12:00:00Z", "2026-01-11T23:00:00.000Z"],
      ["Africa/Johannesburg", "2026-01-08T12:00:00Z", "2026-01-18T22:00:00.000Z"],
      ["Africa/Nairobi", "2026-01-09T12:00:00Z", "2026-01-18T21:00:00.000Z"],
    ],
    after: [["2026-01-14T12:00:00Z", 2]],
  },
  // Accra, Nairobi, Kolkata: as Accra to Kolkata directly, 01-25T18:30Z (round 2 gave 02-01T18:30Z).
  {
    label: "r3-r2-chain-accra-nairobi-kolkata", from: "Africa/Accra", saves: [new Date("2026-01-05T12:00:00Z")],
    readAt: new Date("2026-01-12T12:00:00Z"), start: iso(W2), homeEnd: iso(W3), saved: false, count: 1,
    steps: [
      ["Africa/Nairobi", "2026-01-13T12:00:00Z", "2026-01-25T21:00:00.000Z"],
      ["Asia/Kolkata", "2026-01-15T12:00:00Z", "2026-01-25T18:30:00.000Z"],
    ],
    after: [["2026-01-20T12:00:00Z", 2]],
  },
  // Daily, saved, four changes on one day: each ends at the boundary nearest the home end (01-13T00:00Z), so
  // never at or before the start; a second save that day adds nothing, and the next Lagos day counts.
  {
    label: "r2-g3-start", cadence: "daily", from: "UTC",
    saves: [new Date("2026-01-11T12:00:00Z"), new Date("2026-01-12T00:30:00Z")], readAt: new Date("2026-01-12T00:45:00Z"),
    start: iso(W2), homeEnd: "2026-01-13T00:00:00.000Z", saved: true, count: 2,
    steps: [
      ["Asia/Kolkata", "2026-01-12T01:00:00Z", "2026-01-12T18:30:00.000Z"],
      ["Pacific/Pago_Pago", "2026-01-12T02:00:00Z", "2026-01-13T11:00:00.000Z"],
      ["Pacific/Kiritimati", "2026-01-12T03:00:00Z", "2026-01-13T10:00:00.000Z"],
      ["Africa/Lagos", "2026-01-12T04:00:00Z", "2026-01-12T23:00:00.000Z"],
    ],
    after: [["2026-01-12T05:00:00Z", 2], ["2026-01-12T23:30:00Z", 3]],
  },
  // CAL3-3, pinned (an accepted class A effect on a saved day): London's March 29 is 23 hours, so after Dubai
  // the derived home end is an hour late, 03-30T00:00Z, and Fiji's 12-hour tie goes to the later boundary,
  // 03-30T12:00Z: a save at 20:00Z (March 30 in Fiji) adds nothing. London to Fiji directly ends 03-29T12:00Z.
  {
    label: "r4-cal3-3-london-dubai-fiji-pinned", cadence: "daily", from: "Europe/London",
    saves: [new Date("2026-03-28T12:00:00Z"), new Date("2026-03-29T05:00:00Z")], readAt: new Date("2026-03-29T05:30:00Z"),
    start: "2026-03-29T00:00:00.000Z", homeEnd: "2026-03-29T23:00:00.000Z", saved: true, count: 2,
    steps: [
      ["Asia/Dubai", "2026-03-29T06:00:00Z", "2026-03-29T20:00:00.000Z"],
      ["Pacific/Fiji", "2026-03-29T10:00:00Z", "2026-03-30T12:00:00.000Z"],
    ],
    after: [["2026-03-29T20:00:00Z", 2], ["2026-03-30T13:00:00Z", 3]],
  },
];

/**
 * R1: a resident of a zone whose DST jump skips local midnight saves every day
 * (17:00Z). A read before each save sees that local day open on its bounds, the
 * count unchanged and nothing frozen; each save adds one step; every day is
 * logged saved on its own bounds, 23 to 25 hours long, with no gap.
 */
async function dailyAcrossSkippedMidnight(zone: string, first: string, days: number) {
  const u = await newUser(`r3-r1-resident-${zone.replace("/", "-")}`, "daily", zone);
  const day = (i: number) => Date.parse(`${first}T17:00:00Z`) + i * 86_400_000;
  for (let i = 0; i < days; i++) {
    if (i > 0) {
      const readAt = new Date(day(i) - 5 * HOUR);
      const ov = await getStreakOverview(u, readAt);
      const s = await accountStreak(u);
      const want = localPeriod(readAt, "daily", zone);
      const tag = `${zone} ${iso(readAt)}:`;
      assert(
        s.currentPeriodStart.getTime() === want.start && s.currentPeriodEnd.getTime() === want.end,
        `${tag} open ${iso(new Date(want.start))} to ${iso(new Date(want.end))}, got ${iso(s.currentPeriodStart)} to ${iso(s.currentPeriodEnd)}`,
      );
      assert(ov.hero?.count === i && ov.hero.status === "active", `${tag} ${i} active, got ${JSON.stringify(ov.hero)}`);
    }
    await recordSave(u, `save-${randomUUID()}`, new Date(day(i)));
    const got = (await accountStreak(u)).currentCount;
    assert(got === i + 1, `${zone}: the save on day ${i + 1} gives ${i + 1}, got ${got}`);
  }
  await getStreakOverview(u, new Date(day(days)));
  const rows = await periodRows(u);
  assert(rows.length === days && rows.every((r) => r.outcome === "saved"), `${zone}: ${days} days saved, got ${outcomes(rows)}`);
  for (let i = 0; i < rows.length; i++) {
    const want = localPeriod(new Date(day(i)), "daily", zone);
    const r = rows[i];
    const hours = (r.periodEnd.getTime() - r.periodStart.getTime()) / HOUR;
    assert(
      r.periodStart.getTime() === want.start && r.periodEnd.getTime() === want.end && hours >= 23 && hours <= 25,
      `${zone}: day ${i + 1} is ${iso(new Date(want.start))} to ${iso(new Date(want.end))}, got ${iso(r.periodStart)} to ${iso(r.periodEnd)}`,
    );
    if (i > 0) assert(r.periodStart.getTime() === rows[i - 1].periodEnd.getTime(), `${zone}: day ${i + 1} starts where day ${i} ended`);
  }
  assert(((await freezeRow(u))?.usedTotal ?? 0) === 0, `${zone}: no freeze is used`);
}

/**
 * R4: a close at once does not look at when the satisfying save was made. W1 is
 * saved on Monday; a save at Sunday 21:30Z (Monday 00:30 in Nairobi) races a
 * change to Nairobi at 22:00Z. Save first: it falls in the UTC week already
 * saved (no step), and the Nairobi week then opens not saved. Change first: the
 * week closes as kept, and the save counts for the Nairobi week. A raw client
 * holds the streak row so the order is fixed.
 */
async function closeAtOnceRacingSave(saveFirst: boolean) {
  const u = await newUser(`r3-r4-race-${saveFirst ? "save-first" : "change-first"}`);
  await recordSave(u, `save-${randomUUID()}`, SAVE_W1);
  const { id } = await accountStreak(u);
  const holder = await pool.connect();
  let clean = false;
  try {
    await holder.query("begin");
    await holder.query("select id from streaks where id = $1 for update", [id]);
    const save = () => recordSave(u, `save-${randomUUID()}`, new Date("2026-01-11T21:30:00Z"));
    const change = () => setUserTimezone(u, "Africa/Nairobi", new Date("2026-01-11T22:00:00Z"));
    const first = saveFirst ? save() : change();
    first.catch(() => {});
    await lockWaiters(1);
    const second = saveFirst ? change() : save();
    second.catch(() => {});
    await lockWaiters(2);
    await holder.query("commit");
    clean = true;
    await first;
    await second;
  } finally {
    holder.release(!clean);
  }
  const s = await accountStreak(u);
  const rows = await periodRows(u);
  assert(
    outcomes(rows) === "saved" && iso(rows[0].periodStart) === iso(W1) && iso(rows[0].periodEnd) === "2026-01-11T21:00:00.000Z",
    `W1 closed as kept on the Nairobi boundary, got ${JSON.stringify(rows)}`,
  );
  assert(
    iso(s.currentPeriodStart) === "2026-01-11T21:00:00.000Z" && iso(s.currentPeriodEnd) === "2026-01-18T21:00:00.000Z",
    `the Nairobi week opens, got ${iso(s.currentPeriodStart)} to ${iso(s.currentPeriodEnd)}`,
  );
  const count = saveFirst ? 1 : 2;
  assert(
    s.currentCount === count && s.currentPeriodSatisfied === !saveFirst,
    `${saveFirst ? "save first" : "change first"}: count ${count}, saved ${!saveFirst}, got ${s.currentCount} ${s.currentPeriodSatisfied}`,
  );
}

/**
 * R4, CAL-5: saves an hour apart on either side of a close at once both count.
 * The save at 21:30Z satisfies W1; the change at 22:00Z closes it as kept; the
 * save at 22:30Z counts for the Nairobi week of January 12, which holds both.
 */
async function closeAtOnceTwoSavesBothCount() {
  const u = await newUser("r3-r4-cal5");
  await recordSave(u, `save-${randomUUID()}`, new Date("2026-01-04T12:00:00Z"));
  await recordSave(u, `save-${randomUUID()}`, new Date("2026-01-11T21:30:00Z"));
  assert((await accountStreak(u)).currentCount === 2, "W1's save counts");
  await setUserTimezone(u, "Africa/Nairobi", new Date("2026-01-11T22:00:00Z"));
  let s = await accountStreak(u);
  assert(s.currentCount === 2 && !s.currentPeriodSatisfied, `closed as kept, the Nairobi week open, got ${s.currentCount}`);
  await recordSave(u, `save-${randomUUID()}`, new Date("2026-01-11T22:30:00Z"));
  s = await accountStreak(u);
  assert(s.currentCount === 3, `the save at 22:30Z counts too, got ${s.currentCount}`);
}

/**
 * R5: the freeze cooldown compares local days. January was frozen, so the last
 * use is 2026-02-01T00:00Z and a freeze is allowed again from May 1 (local).
 * April, missed, ends at local midnight on May 1 and can use one.
 */
async function freezeCooldownInLocalDays(c: { label: string; from: string; to?: string }) {
  const u = await newUser(c.label, "monthly", c.from);
  await recordSave(u, `save-${randomUUID()}`, new Date("2025-12-10T12:00:00Z"));
  await getStreakOverview(u, new Date("2026-02-01T06:00:00Z"));
  const f = await freezeRow(u);
  assert(f?.usedTotal === 1 && iso(f.lastUsedAt!) === "2026-02-01T00:00:00.000Z", `January frozen, got ${JSON.stringify(f)}`);
  await recordSave(u, `save-${randomUUID()}`, new Date("2026-02-10T12:00:00Z"));
  await recordSave(u, `save-${randomUUID()}`, new Date("2026-03-10T12:00:00Z"));
  if (c.to) await setUserTimezone(u, c.to, new Date("2026-04-15T12:00:00Z"));
  const ov = await getStreakOverview(u, new Date("2026-05-01T06:00:00Z"));
  const rows = await periodRows(u);
  assert(outcomes(rows) === "saved,frozen,saved,saved,frozen", `April frozen, got ${outcomes(rows)}`);
  assert(iso(rows[4].periodEnd) === "2026-04-30T23:00:00.000Z", `April ends at local midnight, got ${iso(rows[4].periodEnd)}`);
  assert(ov.hero?.count === 3 && ov.hero.status === "frozen", `3 and frozen, got ${JSON.stringify(ov.hero)}`);
  assert((await freezeRow(u))?.usedTotal === 2, "the second freeze is used");
}

/** R5, weekly: the last use was the week ending 2026-04-06T00:00Z; the Nairobi week ending 07-05T21:00Z (July 6 there) may use one. */
async function freezeCooldownWeeklyNairobi() {
  const u = await newUser("r3-r5-weekly-nairobi");
  await db.insert(streaksTable).values({
    userId: u,
    commitmentType: "account",
    commitmentId: u,
    frequency: "weekly",
    startedAt: new Date("2026-03-02T12:00:00Z"),
    status: "active",
    currentCount: 16,
    bestCount: 16,
    currentPeriodStart: new Date("2026-06-22T00:00:00Z"),
    currentPeriodEnd: new Date("2026-06-29T00:00:00Z"),
    currentPeriodSatisfied: true,
  });
  await db.insert(streakFreezesTable).values({
    userId: u,
    balance: 1,
    usedTotal: 1,
    lastUsedAt: new Date("2026-04-06T00:00:00Z"),
    lastGrantedAt: new Date("2026-06-01T00:00:00Z"),
    grantedTotal: 2,
    grantYear: 2026,
    grantsThisYear: 2,
  });
  await setUserTimezone(u, "Africa/Nairobi", new Date("2026-06-24T12:00:00Z"));
  assert(iso((await accountStreak(u)).currentPeriodEnd) === "2026-06-28T21:00:00.000Z", "the saved week ends on the Nairobi boundary");
  const ov = await getStreakOverview(u, new Date("2026-07-06T03:00:00Z"));
  const rows = await periodRows(u);
  assert(outcomes(rows) === "saved,frozen", `the missed Nairobi week is frozen, got ${outcomes(rows)}`);
  assert(iso(rows[1].periodEnd) === "2026-07-05T21:00:00.000Z", `it ends July 6 there, got ${iso(rows[1].periodEnd)}`);
  assert(ov.hero?.count === 16 && ov.hero.status === "frozen", `16 and frozen, got ${JSON.stringify(ov.hero)}`);
}

/**
 * R6: one badge per milestone, labels rising within a run. Milestone 1
 * (2026-04-01T05:00Z) is labelled in the first zone; after a change, milestone 2
 * (2026-07-01T05:00Z) gets its quarter in the new zone, or, when the run already
 * holds that quarter, the quarter after the run's latest badge. Reads add nothing.
 */
async function badgesAcrossZoneChange(c: { label: string; from: string; to: string; first: string; second: string }) {
  const u = await newUser(c.label, "weekly", c.from);
  await insertQuarterStreak(u);
  let ov = await getStreakOverview(u, new Date("2026-04-06T12:00:00Z"));
  assert(ov.badges.map((b) => b.badgeKey).join() === c.first, `${c.label}: ${c.first}, got ${JSON.stringify(ov.badges)}`);
  await setUserTimezone(u, c.to, new Date("2026-04-08T00:00:00Z"));
  // The settle after the change (the week missed, the granted freeze used) awards nothing.
  ov = await getStreakOverview(u, new Date((await accountStreak(u)).currentPeriodEnd.getTime() + HOUR));
  assert(ov.hero?.status === "frozen", `${c.label}: the run is alive, got ${JSON.stringify(ov.hero)}`);
  assert(ov.badges.length === 1, `${c.label}: the change adds no badge, got ${JSON.stringify(ov.badges)}`);
  // Keep the run alive into July: the new zone's week of June 15, saved.
  const week = localPeriod(new Date("2026-06-17T12:00:00Z"), "weekly", c.to);
  await db
    .update(streaksTable)
    .set({ currentPeriodStart: new Date(week.start), currentPeriodEnd: new Date(week.end), currentPeriodSatisfied: true, status: "active" })
    .where(eq(streaksTable.userId, u));
  await recordSave(u, `save-${randomUUID()}`, new Date("2026-06-24T12:00:00Z"));
  ov = await getStreakOverview(u, new Date("2026-07-02T12:00:00Z"));
  const keys = ov.badges.map((b) => b.badgeKey).join();
  assert(keys === `${c.first},${c.second}`, `${c.label}: ${c.first},${c.second}, got ${keys}`);
  await recordSave(u, `save-${randomUUID()}`, new Date("2026-07-03T12:00:00Z"));
  ov = await getStreakOverview(u, new Date("2026-07-07T12:00:00Z"));
  assert(ov.hero?.status === "active", `${c.label}: still alive, got ${JSON.stringify(ov.hero)}`);
  assert(ov.badges.map((b) => b.badgeKey).join() === keys, `${c.label}: a later read adds nothing, got ${JSON.stringify(ov.badges)}`);
  const rows = await db.select().from(streakBadgesTable).where(eq(streakBadgesTable.userId, u));
  assert(rows.length === 2, `${c.label}: two badge rows, got ${rows.length}`);
}

/**
 * R7: a revive never starts inside a period already logged. W2 is missed (no
 * freeze), so the change to Johannesburg settles it in UTC first and the streak
 * breaks; the Johannesburg week holding the reviving save began at
 * 01-18T22:00Z, inside W2, so the revived period starts where W2 ended.
 */
async function reviveDoesNotOverlap() {
  const u = await newUser("r3-r7-revive");
  await recordSave(u, `save-${randomUUID()}`, SAVE_W1);
  await db.insert(streakFreezesTable).values({
    userId: u,
    balance: 0,
    lastGrantedAt: new Date("2026-01-20T12:00:00Z"),
    grantYear: 2026,
    grantsThisYear: 1,
  });
  await setUserTimezone(u, "Africa/Johannesburg", new Date("2026-01-20T12:00:00Z"));
  let s = await accountStreak(u);
  assert(outcomes(await periodRows(u)) === "saved,missed" && s.status === "broken", `W2 missed and broken, got ${s.status}`);
  assert(iso(s.currentPeriodEnd) === "2026-02-01T22:00:00.000Z", `W3 runs to a Johannesburg boundary, got ${iso(s.currentPeriodEnd)}`);
  await recordSave(u, `save-${randomUUID()}`, new Date("2026-01-21T12:00:00Z"));
  s = await accountStreak(u);
  assert(
    iso(s.currentPeriodStart) === iso(W3) && iso(s.currentPeriodEnd) === "2026-01-25T22:00:00.000Z",
    `revived from W2's end to the next Johannesburg boundary, got ${iso(s.currentPeriodStart)} to ${iso(s.currentPeriodEnd)}`,
  );
  assert(s.currentCount === 1 && s.status === "active" && s.currentPeriodSatisfied, `1, active, saved, got ${s.currentCount} ${s.status}`);
  await getStreakOverview(u, new Date("2026-01-26T12:00:00Z"));
  const rows = await periodRows(u);
  assert(outcomes(rows) === "saved,missed,saved", `logged saved, missed, saved, got ${outcomes(rows)}`);
  for (let i = 1; i < rows.length; i++) {
    assert(rows[i].periodStart.getTime() >= rows[i - 1].periodEnd.getTime(), `row ${i + 1} does not overlap row ${i}`);
  }
}

/** R8: a change that moves the end later clears the reminder mark; one that moves it earlier keeps it. */
async function reminderMarkAfterChange() {
  for (const [zone, end, cleared] of [
    ["Africa/Nairobi", "2026-01-18T21:00:00.000Z", true],
    ["Africa/Lagos", "2026-01-11T23:00:00.000Z", false],
  ] as const) {
    const u = await newUser(`r3-r8-${zone.replace("/", "-")}`);
    await recordSave(u, `save-${randomUUID()}`, PREV_SAVE);
    await getStreakOverview(u, new Date("2026-01-09T12:00:00Z"));
    // As sendReminders marks a reminder sent for the open period.
    await db.update(streaksTable).set({ reminderSentPeriodStart: W1 }).where(eq(streaksTable.userId, u));
    await setUserTimezone(u, zone, new Date("2026-01-10T12:00:00Z"));
    const s = await accountStreak(u);
    assert(iso(s.currentPeriodEnd) === end, `${zone}: ends ${end}, got ${iso(s.currentPeriodEnd)}`);
    const mark = s.reminderSentPeriodStart ? iso(s.reminderSentPeriodStart) : null;
    assert(mark === (cleared ? null : iso(W1)), `${zone}: reminder mark ${cleared ? "cleared" : "kept"}, got ${mark}`);
  }
}

/**
 * An unsaved week stretched by a change to Nairobi while a break is on (from
 * 01-06T12:00Z for `days` days): the break runs past the stretched end, or ends
 * inside the stretch after the home end. The home end passing closes nothing,
 * and the week closes paused at its stretched end, never frozen or missed.
 */
async function stretchWithBreak(c: { label: string; days: number; statusAfter: string }) {
  const u = await newUser(c.label);
  await recordSave(u, `save-${randomUUID()}`, PREV_SAVE);
  await startVacation(u, c.days, new Date("2026-01-06T12:00:00Z"));
  await setUserTimezone(u, "Africa/Nairobi", new Date("2026-01-07T12:00:00Z"));
  let s = await accountStreak(u);
  assert(
    iso(s.currentPeriodStart) === iso(W1) && iso(s.currentPeriodEnd) === "2026-01-18T21:00:00.000Z" && s.status === "paused",
    `${c.label}: stretched to 01-18T21:00Z, paused, got ${iso(s.currentPeriodEnd)} ${s.status}`,
  );
  let ov = await getStreakOverview(u, new Date("2026-01-12T01:00:00Z"));
  assert(ov.hero?.count === 1 && outcomes(await periodRows(u)) === "saved", `${c.label}: nothing closes at the home end`);
  ov = await getStreakOverview(u, new Date("2026-01-19T00:00:00Z"));
  const rows = await periodRows(u);
  assert(
    outcomes(rows) === "saved,paused" && iso(rows[1].periodStart) === iso(W1) && iso(rows[1].periodEnd) === "2026-01-18T21:00:00.000Z",
    `${c.label}: the week logged paused on its bounds, got ${outcomes(rows)}`,
  );
  s = await accountStreak(u);
  assert(ov.hero?.count === 1 && s.status === c.statusAfter, `${c.label}: 1 and ${c.statusAfter}, got ${JSON.stringify(ov.hero)} ${s.status}`);
  assert(((await freezeRow(u))?.usedTotal ?? 0) === 0, `${c.label}: no freeze is used`);
}

/** Example 5 during a break: the week the change closes is logged paused, as any settle logs it. */
async function zoneChangeClosesPeriodOnBreak() {
  const u = await newUser("r2-05-break");
  await recordSave(u, `save-${randomUUID()}`, SAVE_W1);
  await startVacation(u, 7, new Date("2026-01-10T12:00:00Z"));
  await setUserTimezone(u, "Africa/Nairobi", new Date("2026-01-11T22:00:00Z"));
  const s = await accountStreak(u);
  assert(
    iso(s.currentPeriodStart) === "2026-01-11T21:00:00.000Z" && iso(s.currentPeriodEnd) === "2026-01-18T21:00:00.000Z",
    `the Nairobi week opens, got ${iso(s.currentPeriodStart)} to ${iso(s.currentPeriodEnd)}`,
  );
  assert(s.currentCount === 1 && s.status === "paused" && !s.currentPeriodSatisfied, `1, paused, open, got ${s.currentCount} ${s.status}`);
  const rows = await periodRows(u);
  assert(outcomes(rows) === "paused" && iso(rows[0].periodEnd) === "2026-01-11T21:00:00.000Z", `logged paused, got ${outcomes(rows)}`);
  assert(((await freezeRow(u))?.usedTotal ?? 0) === 0, "no freeze is used");
}

/** Example 14: the open period has closed when the change arrives; it is settled in UTC first. */
async function zoneChangeAfterClose() {
  const u = await zoneRule({
    label: "r2-14-lagos-after-close",
    zone: "Africa/Lagos",
    saves: [SAVE_W1],
    changeAt: new Date("2026-01-14T12:00:00Z"),
    oldEnd: iso(W3),
    start: iso(W2),
    end: "2026-01-18T23:00:00.000Z",
    saved: false,
    count: 1,
    logged: "saved",
    nextSave: new Date("2026-01-15T12:00:00Z"),
  });
  const [first] = await periodRows(u);
  assert(iso(first.periodStart) === iso(W1) && iso(first.periodEnd) === iso(W2), "week 1 keeps its UTC bounds");
}

// --- Fix round 4 ---------------------------------------------------------------

type ScriptStep =
  | { save: string; count: number; open?: [start: string, end: string] }
  | { read: string; outcomes?: string }
  | {
      zone: string;
      at: string;
      /** The open period afterwards. */
      start: string;
      end: string;
      saved: boolean;
      count: number;
      status?: string;
      /** A close at once: the one row the change logs, saved. */
      closed?: [start: string, end: string];
    };

/**
 * Saves, reads and changes in order. Each save gives its count. Each change
 * finds its open period still open; afterwards the open period's bounds, saved
 * or not, the count and the status; the change uses no freeze, and it logs
 * nothing, or, when it closes the period at once, exactly one saved row on the
 * given bounds (G1, G2). A read can check every row's outcome.
 */
type ScriptCase = { label: string; cadence?: Frequency; from: string; noFreeze?: boolean; steps: ScriptStep[] };

async function zoneScript(c: ScriptCase) {
  const u = await newUser(c.label, c.cadence ?? "weekly", c.from);
  if (c.noFreeze) {
    // No freeze to use, and none due in the test's dates.
    await db.insert(streakFreezesTable).values({ userId: u, balance: 0, lastGrantedAt: new Date("2027-06-01T00:00:00Z"), grantYear: 2026, grantsThisYear: 4 });
  }
  for (const step of c.steps) {
    if ("save" in step) {
      await recordSave(u, `save-${randomUUID()}`, new Date(step.save));
      const s = await accountStreak(u);
      assert(s.currentCount === step.count, `${c.label}: the save at ${step.save} gives ${step.count}, got ${s.currentCount}`);
      if (step.open) {
        const got = `${iso(s.currentPeriodStart)} to ${iso(s.currentPeriodEnd)}`;
        assert(got === `${step.open[0]} to ${step.open[1]}`, `${c.label}: the save at ${step.save} opens ${step.open.join(" to ")}, got ${got}`);
      }
    } else if ("read" in step) {
      await getStreakOverview(u, new Date(step.read));
      if (step.outcomes !== undefined) {
        const got = outcomes(await periodRows(u));
        assert(got === step.outcomes, `${c.label}: at ${step.read} the rows are ${step.outcomes}, got ${got}`);
      }
    } else {
      const tag = `${c.label}: ${step.zone} at ${step.at}:`;
      const before = await accountStreak(u);
      assert(before.currentPeriodEnd.getTime() > Date.parse(step.at), `${tag} the open period has not closed`);
      const logged = (await periodRows(u)).length;
      const used = (await freezeRow(u))?.usedTotal ?? 0;
      await setUserTimezone(u, step.zone, new Date(step.at));
      const s = await accountStreak(u);
      const rows = (await periodRows(u)).slice(logged);
      assert(outcomes(rows) === (step.closed ? "saved" : ""), `${tag} logs ${step.closed ? "one saved row" : "nothing"}, got "${outcomes(rows)}"`);
      if (step.closed) {
        const got = `${iso(rows[0].periodStart)} to ${iso(rows[0].periodEnd)}`;
        assert(got === `${step.closed[0]} to ${step.closed[1]}`, `${tag} closes ${step.closed.join(" to ")}, got ${got}`);
      }
      const open = `${iso(s.currentPeriodStart)} to ${iso(s.currentPeriodEnd)}`;
      assert(open === `${step.start} to ${step.end}`, `${tag} open ${step.start} to ${step.end}, got ${open}`);
      const status = step.status ?? "active";
      assert(
        s.currentPeriodSatisfied === step.saved && s.currentCount === step.count && s.status === status,
        `${tag} ${step.saved} ${step.count} ${status}, got ${s.currentPeriodSatisfied} ${s.currentCount} ${s.status}`,
      );
      assert(((await freezeRow(u))?.usedTotal ?? 0) === used, `${tag} no freeze is used`);
    }
  }
}

const SCRIPT_CASES: ScriptCase[] = [
  // CAL3-1: daily, Denver, November 1 is 25 hours (06:00Z to 07:00Z next day). Karachi lands on a 12-hour
  // tie (the later boundary, 11-02T19:00Z); Kolkata then measures from the derived home end, an hour early,
  // and its nearest boundary (11-01T18:30Z) has passed: the day closes at once as kept, up to the Kolkata
  // day holding now, never walking an unsaved Kolkata day.
  {
    label: "r4-cal3-1-denver-karachi-kolkata", cadence: "daily", from: "America/Denver",
    steps: [
      { save: "2026-10-31T18:00:00Z", count: 1 },
      { save: "2026-11-01T18:00:00Z", count: 2 },
      { zone: "Asia/Karachi", at: "2026-11-02T03:00:00Z", start: "2026-11-01T06:00:00.000Z", end: "2026-11-02T19:00:00.000Z", saved: true, count: 2 },
      {
        zone: "Asia/Kolkata", at: "2026-11-02T18:45:00Z", closed: ["2026-11-01T06:00:00.000Z", "2026-11-02T18:30:00.000Z"],
        start: "2026-11-02T18:30:00.000Z", end: "2026-11-03T18:30:00.000Z", saved: false, count: 2,
      },
      { save: "2026-11-02T19:00:00Z", count: 3 },
      { read: "2026-11-03T19:00:00Z", outcomes: "saved,saved,saved" },
    ],
  },
  // CAL3-1: daily, Paris (October 25 is 25 hours), no freeze to use: Auckland (a tie, the later), then Chatham.
  {
    label: "r4-cal3-1-paris-auckland-chatham", cadence: "daily", from: "Europe/Paris", noFreeze: true,
    steps: [
      { save: "2026-10-24T12:00:00Z", count: 1 },
      { save: "2026-10-25T12:00:00Z", count: 2 },
      { zone: "Pacific/Auckland", at: "2026-10-25T12:00:00Z", start: "2026-10-24T22:00:00.000Z", end: "2026-10-26T11:00:00.000Z", saved: true, count: 2 },
      {
        zone: "Pacific/Chatham", at: "2026-10-26T10:30:00Z", closed: ["2026-10-24T22:00:00.000Z", "2026-10-26T10:15:00.000Z"],
        start: "2026-10-26T10:15:00.000Z", end: "2026-10-27T10:15:00.000Z", saved: false, count: 2,
      },
      { save: "2026-10-26T11:00:00Z", count: 3 },
    ],
  },
  // CAL3-1: daily, Los Angeles (November 1 is 25 hours), then Dubai (a tie), then Kabul.
  {
    label: "r4-cal3-1-la-dubai-kabul", cadence: "daily", from: "America/Los_Angeles",
    steps: [
      { save: "2026-10-31T18:00:00Z", count: 1 },
      { save: "2026-11-01T18:00:00Z", count: 2 },
      { zone: "Asia/Dubai", at: "2026-11-02T06:00:00Z", start: "2026-11-01T07:00:00.000Z", end: "2026-11-02T20:00:00.000Z", saved: true, count: 2 },
      {
        zone: "Asia/Kabul", at: "2026-11-02T19:45:00Z", closed: ["2026-11-01T07:00:00.000Z", "2026-11-02T19:30:00.000Z"],
        start: "2026-11-02T19:30:00.000Z", end: "2026-11-03T19:30:00.000Z", saved: false, count: 2,
      },
      { save: "2026-11-02T20:00:00Z", count: 3 },
    ],
  },
  // RB3-1 (a): example 4 continued. Nairobi stretches the unsaved week to 01-18T21:00Z; a save on 01-14 counts;
  // Tokyo's boundary nearest the home end (01-11T15:00Z) is a whole Tokyo week before now, so the week closes
  // at the start of the Tokyo week holding now, and the Tokyo week of January 12 (which holds the save) is
  // never walked as unsaved. With a freeze to use, and without.
  ...[false, true].map((noFreeze): ScriptCase => ({
    label: `r4-rb3-1-a-utc-nairobi-tokyo${noFreeze ? "-no-freeze" : ""}`, from: "UTC", noFreeze,
    steps: [
      { save: "2025-12-29T12:00:00Z", count: 1 },
      { read: "2026-01-07T12:00:00Z" },
      { zone: "Africa/Nairobi", at: "2026-01-07T12:00:00Z", start: iso(W1), end: "2026-01-18T21:00:00.000Z", saved: false, count: 1 },
      { save: "2026-01-14T12:00:00Z", count: 2 },
      {
        zone: "Asia/Tokyo", at: "2026-01-18T16:00:00Z", closed: [iso(W1), "2026-01-18T15:00:00.000Z"],
        start: "2026-01-18T15:00:00.000Z", end: "2026-01-25T15:00:00.000Z", saved: false, count: 2,
      },
      { save: "2026-01-19T12:00:00Z", count: 3 },
      { read: "2026-01-26T12:00:00Z", outcomes: "saved,saved,saved" },
    ],
  })),
  // RB3-1 (b): the main markets, weekly. Lagos via Nairobi to Dubai; Accra via Johannesburg to Nairobi; UTC via
  // Lagos (R3's last-hour case) to Johannesburg.
  {
    label: "r4-rb3-1-b-lagos-nairobi-dubai", from: "Africa/Lagos",
    steps: [
      { save: "2025-12-29T12:00:00Z", count: 1 },
      { read: "2026-01-07T12:00:00Z" },
      { zone: "Africa/Nairobi", at: "2026-01-07T12:00:00Z", start: "2026-01-04T23:00:00.000Z", end: "2026-01-18T21:00:00.000Z", saved: false, count: 1 },
      { save: "2026-01-14T12:00:00Z", count: 2 },
      {
        zone: "Asia/Dubai", at: "2026-01-18T20:30:00Z", closed: ["2026-01-04T23:00:00.000Z", "2026-01-18T20:00:00.000Z"],
        start: "2026-01-18T20:00:00.000Z", end: "2026-01-25T20:00:00.000Z", saved: false, count: 2,
      },
      { save: "2026-01-19T12:00:00Z", count: 3 },
    ],
  },
  {
    label: "r4-rb3-1-b-accra-johannesburg-nairobi", from: "Africa/Accra",
    steps: [
      { save: "2025-12-29T12:00:00Z", count: 1 },
      { read: "2026-01-07T12:00:00Z" },
      { zone: "Africa/Johannesburg", at: "2026-01-07T12:00:00Z", start: iso(W1), end: "2026-01-18T22:00:00.000Z", saved: false, count: 1 },
      { save: "2026-01-14T12:00:00Z", count: 2 },
      {
        zone: "Africa/Nairobi", at: "2026-01-18T21:30:00Z", closed: [iso(W1), "2026-01-18T21:00:00.000Z"],
        start: "2026-01-18T21:00:00.000Z", end: "2026-01-25T21:00:00.000Z", saved: false, count: 2,
      },
      { save: "2026-01-19T12:00:00Z", count: 3 },
    ],
  },
  {
    label: "r4-rb3-1-b-utc-lagos-johannesburg", from: "UTC",
    steps: [
      { save: "2025-12-29T12:00:00Z", count: 1 },
      { read: "2026-01-11T23:30:00Z" },
      { zone: "Africa/Lagos", at: "2026-01-11T23:30:00Z", start: iso(W1), end: "2026-01-18T23:00:00.000Z", saved: false, count: 1 },
      { save: "2026-01-14T12:00:00Z", count: 2 },
      {
        zone: "Africa/Johannesburg", at: "2026-01-18T22:30:00Z", closed: [iso(W1), "2026-01-18T22:00:00.000Z"],
        start: "2026-01-18T22:00:00.000Z", end: "2026-01-25T22:00:00.000Z", saved: false, count: 2,
      },
      { save: "2026-01-19T12:00:00Z", count: 3 },
    ],
  },
  // RB3-1 (c): the CAL-2 chain (Accra, Lagos, Johannesburg) continued: Nairobi near the stretched end closes the
  // week at the Nairobi week holding now. With a freeze to use, and without.
  ...[false, true].map((noFreeze): ScriptCase => ({
    label: `r4-rb3-1-c-accra-lagos-johannesburg-nairobi${noFreeze ? "-no-freeze" : ""}`, from: "Africa/Accra", noFreeze,
    steps: [
      { save: "2026-01-05T12:00:00Z", count: 1 },
      { read: "2026-01-12T12:00:00Z" },
      { zone: "Africa/Lagos", at: "2026-01-13T12:00:00Z", start: iso(W2), end: "2026-01-18T23:00:00.000Z", saved: false, count: 1 },
      { zone: "Africa/Johannesburg", at: "2026-01-15T12:00:00Z", start: iso(W2), end: "2026-01-25T22:00:00.000Z", saved: false, count: 1 },
      { save: "2026-01-18T22:30:00Z", count: 2 },
      {
        zone: "Africa/Nairobi", at: "2026-01-25T21:30:00Z", closed: [iso(W2), "2026-01-25T21:00:00.000Z"],
        start: "2026-01-25T21:00:00.000Z", end: "2026-02-01T21:00:00.000Z", saved: false, count: 2,
      },
      { save: "2026-01-26T12:00:00Z", count: 3 },
    ],
  })),
  // RB3-1 (d): daily, Paris, three saves after Kolkata's stretch, then Pago Pago.
  {
    label: "r4-rb3-1-d-paris-kolkata-pago-pago", cadence: "daily", from: "Europe/Paris",
    steps: [
      { save: "2026-04-25T13:24:00Z", count: 1 },
      { read: "2026-04-26T02:59:00Z" },
      { zone: "Asia/Kolkata", at: "2026-04-26T02:59:00Z", start: "2026-04-25T22:00:00.000Z", end: "2026-04-27T18:30:00.000Z", saved: false, count: 1 },
      { save: "2026-04-26T13:13:00Z", count: 2 },
      { save: "2026-04-27T01:13:00Z", count: 2 },
      { save: "2026-04-27T06:12:00Z", count: 2 },
      {
        zone: "Pacific/Pago_Pago", at: "2026-04-27T17:49:00Z", closed: ["2026-04-25T22:00:00.000Z", "2026-04-27T11:00:00.000Z"],
        start: "2026-04-27T11:00:00.000Z", end: "2026-04-28T11:00:00.000Z", saved: false, count: 2,
      },
      { save: "2026-04-27T18:00:00Z", count: 3 },
      { read: "2026-04-28T12:00:00Z", outcomes: "saved,saved,saved" },
    ],
  },
  // CAL3-2: a change after a revive that R7 trimmed. UTC, weekly, W2 missed; New York stretches the broken W3;
  // a save on Sunday evening there revives the New York week of January 12 from W2's end, 5 hours. Chicago
  // then measures from that end: the Chicago boundary nearest it, 01-19T06:00Z, so the Chicago week of
  // January 19 counts. Toronto (New York's boundaries) keeps 01-19T05:00Z.
  ...(["America/Chicago", "America/Toronto"] as const).map((zone): ScriptCase => ({
    label: `r4-cal3-2-weekly-new-york-${zone === "America/Chicago" ? "chicago" : "toronto"}`, from: "UTC", noFreeze: true,
    steps: [
      { save: "2026-01-07T15:00:00Z", count: 1 },
      { read: "2026-01-19T00:30:00Z", outcomes: "saved,missed" },
      { zone: "America/New_York", at: "2026-01-19T01:00:00Z", start: iso(W3), end: "2026-01-26T05:00:00.000Z", saved: false, count: 0, status: "broken" },
      { save: "2026-01-19T01:30:00Z", count: 1, open: [iso(W3), "2026-01-19T05:00:00.000Z"] },
      {
        zone, at: "2026-01-19T03:00:00Z", start: iso(W3),
        end: zone === "America/Chicago" ? "2026-01-19T06:00:00.000Z" : "2026-01-19T05:00:00.000Z", saved: true, count: 1,
      },
      { save: "2026-01-21T15:00:00Z", count: 2 },
      { read: "2026-01-27T12:00:00Z", outcomes: "saved,missed,saved,saved" },
    ],
  })),
  // CAL3-2, daily: the same on January 14; the Chicago day of January 14 counts.
  {
    label: "r4-cal3-2-daily-new-york-chicago", cadence: "daily", from: "UTC", noFreeze: true,
    steps: [
      { save: "2026-01-12T15:00:00Z", count: 1 },
      { read: "2026-01-14T00:30:00Z", outcomes: "saved,missed" },
      { zone: "America/New_York", at: "2026-01-14T01:00:00Z", start: "2026-01-14T00:00:00.000Z", end: "2026-01-15T05:00:00.000Z", saved: false, count: 0, status: "broken" },
      { save: "2026-01-14T01:30:00Z", count: 1, open: ["2026-01-14T00:00:00.000Z", "2026-01-14T05:00:00.000Z"] },
      { zone: "America/Chicago", at: "2026-01-14T03:00:00Z", start: "2026-01-14T00:00:00.000Z", end: "2026-01-14T06:00:00.000Z", saved: true, count: 1 },
      { save: "2026-01-14T15:00:00Z", count: 2 },
      { read: "2026-01-15T12:00:00Z", outcomes: "saved,missed,saved,saved" },
    ],
  },
  // RB3-2: Nairobi, weekly, broken; UTC stretches the open Nairobi week; a save revives it trimmed to 3 hours
  // (to 01-19T00:00Z); Lagos's nearest boundary (01-18T23:00Z) has passed, so it closes at once as kept and
  // the Lagos week opens: a save there counts.
  {
    label: "r4-rb3-2-weekly-nairobi-utc-lagos", from: "Africa/Nairobi", noFreeze: true,
    steps: [
      { save: "2025-12-29T12:00:00Z", count: 1 },
      { read: "2026-01-18T21:10:00Z", outcomes: "saved,missed,missed" },
      { zone: "UTC", at: "2026-01-18T21:20:00Z", start: "2026-01-18T21:00:00.000Z", end: "2026-01-26T00:00:00.000Z", saved: false, count: 0, status: "broken" },
      { save: "2026-01-18T22:00:00Z", count: 1, open: ["2026-01-18T21:00:00.000Z", iso(W3)] },
      {
        zone: "Africa/Lagos", at: "2026-01-18T23:30:00Z", closed: ["2026-01-18T21:00:00.000Z", "2026-01-18T23:00:00.000Z"],
        start: "2026-01-18T23:00:00.000Z", end: "2026-01-25T23:00:00.000Z", saved: false, count: 1,
      },
      { save: "2026-01-21T12:00:00Z", count: 2 },
    ],
  },
  // RB3-2, daily: Nairobi, broken; London at 21:30Z; a save at 22:00Z; Paris at 23:30Z; tomorrow's Paris save counts.
  {
    label: "r4-rb3-2-daily-nairobi-london-paris", cadence: "daily", from: "Africa/Nairobi", noFreeze: true,
    steps: [
      { save: "2026-01-10T12:00:00Z", count: 1 },
      { read: "2026-01-12T21:10:00Z", outcomes: "saved,missed,missed" },
      { zone: "Europe/London", at: "2026-01-12T21:30:00Z", start: "2026-01-12T21:00:00.000Z", end: "2026-01-14T00:00:00.000Z", saved: false, count: 0, status: "broken" },
      { save: "2026-01-12T22:00:00Z", count: 1, open: ["2026-01-12T21:00:00.000Z", "2026-01-13T00:00:00.000Z"] },
      {
        zone: "Europe/Paris", at: "2026-01-12T23:30:00Z", closed: ["2026-01-12T21:00:00.000Z", "2026-01-12T23:00:00.000Z"],
        start: "2026-01-12T23:00:00.000Z", end: "2026-01-13T23:00:00.000Z", saved: false, count: 1,
      },
      { save: "2026-01-13T12:00:00Z", count: 2 },
    ],
  },
];

/**
 * RB3-3: a save stamped before the end of a period a read has just logged (it
 * waited for the lock) revives the open period, never the logged one. Daily,
 * no freeze: a read at 01-03T00:00:05Z logs January 2 missed; then a save
 * stamped 01-02T23:59:59Z.
 */
async function reviveAfterLaterSettle() {
  const u = await newUser("r4-rb3-3-late-save", "daily");
  await db.insert(streakFreezesTable).values({ userId: u, balance: 0, lastGrantedAt: new Date("2027-06-01T00:00:00Z"), grantYear: 2026, grantsThisYear: 4 });
  await recordSave(u, `save-${randomUUID()}`, new Date("2026-01-01T12:00:00Z"));
  await getStreakOverview(u, new Date("2026-01-03T00:00:05Z"));
  assert(outcomes(await periodRows(u)) === "saved,missed" && (await accountStreak(u)).status === "broken", "January 2 missed, broken");
  await recordSave(u, `save-${randomUUID()}`, new Date("2026-01-02T23:59:59Z"));
  let s = await accountStreak(u);
  assert(
    iso(s.currentPeriodStart) === "2026-01-03T00:00:00.000Z" && iso(s.currentPeriodEnd) === "2026-01-04T00:00:00.000Z",
    `the open day revives, got ${iso(s.currentPeriodStart)} to ${iso(s.currentPeriodEnd)}`,
  );
  assert(s.currentCount === 1 && s.currentPeriodSatisfied && s.status === "active", `1, saved, active, got ${s.currentCount} ${s.status}`);
  await getStreakOverview(u, new Date("2026-01-04T00:00:05Z"));
  s = await accountStreak(u);
  assert(outcomes(await periodRows(u)) === "saved,missed,saved", `January 3 logged saved, got ${outcomes(await periodRows(u))}`);
  assert(s.currentCount === 1 && s.status === "active", `still 1 and active, got ${s.currentCount} ${s.status}`);
}

/**
 * RB3-4: an earlier run's badge holds 2026 Q2, the quarter of this run's first
 * milestone (2026-07-01T10:30Z is June 30 in Pago Pago). The milestone takes the
 * next free quarter, so each milestone owns one of this run's badges and a
 * repeat read adds nothing.
 */
async function badgeAfterEarlierRun() {
  const zone = "Pacific/Pago_Pago";
  const u = await newUser("r4-rb3-4-badge-collision", "daily", zone);
  const startedAt = new Date("2026-04-01T10:30:00Z");
  await db.insert(streakBadgesTable).values({ userId: u, badgeKey: "2026-q2", year: 2026, quarterIndex: 2, earnedAt: new Date("2026-03-01T00:00:00Z") });
  await db.insert(streaksTable).values({
    userId: u, commitmentType: "account", commitmentId: u, frequency: "daily", startedAt, status: "active",
    currentCount: 90, bestCount: 90, currentPeriodStart: startedAt, currentPeriodEnd: new Date(startedAt.getTime() + DAY), currentPeriodSatisfied: true,
  });
  const runBadges = async () =>
    (await db.select().from(streakBadgesTable).where(eq(streakBadgesTable.userId, u)).orderBy(asc(streakBadgesTable.year), asc(streakBadgesTable.quarterIndex)))
      .filter((b) => b.earnedAt.getTime() >= startedAt.getTime())
      .map((b) => b.badgeKey)
      .join();
  for (const [readAt, want] of [
    ["2026-07-02T12:00:00Z", "2026-q3"],
    ["2026-10-02T12:00:00Z", "2026-q3,2026-q4"],
    ["2026-10-03T12:00:00Z", "2026-q3,2026-q4"],
    ["2027-01-02T12:00:00Z", "2026-q3,2026-q4,2027-q1"],
  ]) {
    // The run kept alive: yesterday there, saved, closes at this read.
    const day = localPeriod(new Date(Date.parse(readAt) - DAY), "daily", zone);
    await db
      .update(streaksTable)
      .set({ currentPeriodStart: new Date(day.start), currentPeriodEnd: new Date(day.end), currentPeriodSatisfied: true, status: "active" })
      .where(eq(streaksTable.userId, u));
    const ov = await getStreakOverview(u, new Date(readAt));
    assert(ov.hero?.status === "active", `the run is alive at ${readAt}, got ${JSON.stringify(ov.hero)}`);
    const got = await runBadges();
    assert(got === want, `this run's badges at ${readAt} are ${want}, got ${got}`);
  }
}

/**
 * CAL3-5: the 3-month freeze cooldown runs on the local calendar. A freeze used
 * for the week ending `lastUsed` may be used again from that local date three
 * months on: Lagos, Monday August 31 there, so the week ending Monday November
 * 30 may use one; London, Monday August 17 (BST), so the week ending November
 * 16 may not and the week ending November 23 may.
 */
async function freezeCooldownLocalCalendar(c: { label: string; zone: string; lastUsed: string; open: [string, string]; readAt: string; frozen: boolean }) {
  const u = await newUser(c.label, "weekly", c.zone);
  await db.insert(streaksTable).values({
    userId: u, commitmentType: "account", commitmentId: u, frequency: "weekly", startedAt: new Date("2026-06-01T12:00:00Z"),
    status: "active", currentCount: 12, bestCount: 12, currentPeriodStart: new Date(c.open[0]), currentPeriodEnd: new Date(c.open[1]),
    currentPeriodSatisfied: true,
  });
  await db.insert(streakFreezesTable).values({
    userId: u, balance: 1, usedTotal: 1, lastUsedAt: new Date(c.lastUsed), lastGrantedAt: new Date("2026-10-01T00:00:00Z"),
    grantedTotal: 2, grantYear: 2026, grantsThisYear: 2,
  });
  const ov = await getStreakOverview(u, new Date(c.readAt));
  const rows = await periodRows(u);
  const want = c.frozen ? "saved,frozen" : "saved,missed";
  assert(outcomes(rows) === want, `${c.label}: ${want}, got ${outcomes(rows)}`);
  const hero = c.frozen ? ov.hero?.count === 12 && ov.hero.status === "frozen" : ov.hero === null;
  assert(hero, `${c.label}: ${c.frozen ? "12 and frozen" : "broken"}, got ${JSON.stringify(ov.hero)}`);
}

/** Wait until `n` of this test's connections are waiting for a lock. */
async function lockWaiters(n: number): Promise<void> {
  for (let i = 0; i < 250; i++) {
    const { rows } = await pool.query<{ n: number }>(
      "select count(*)::int as n from pg_stat_activity where datname = current_database() and application_name = $1 and wait_event_type = 'Lock'",
      [APP_NAME],
    );
    if (rows[0].n >= n) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for ${n} lock waiter(s)`);
}

/**
 * A zone change racing a settle that inserts a freeze and a badge row. The settle
 * holds the streak row; the change holds the user row and waits for the streak;
 * the settle's inserts then check their foreign key on the user row (FOR KEY
 * SHARE). Held FOR UPDATE, the user row would close a cycle and Postgres would
 * abort one side as a deadlock; FOR NO KEY UPDATE lets the inserts through. A raw
 * client plays the settle, in settleDueStreak's lock order, so the order is fixed.
 */
async function zoneChangeRacingSettle() {
  const u = await newUser("c3-race-settle");
  await recordSave(u, `save-${randomUUID()}`, SAVE_W1);
  const { id } = await accountStreak(u);
  const settle = await pool.connect();
  let clean = false;
  try {
    await settle.query("begin");
    await settle.query("set local lock_timeout = '5s'");
    await settle.query("select id from streaks where id = $1 for update", [id]);
    const change = setUserTimezone(u, "America/Los_Angeles", new Date("2026-01-08T12:00:00Z"));
    change.catch(() => {});
    await lockWaiters(1);
    await settle.query("insert into streak_freezes (user_id) values ($1)", [u]);
    await settle.query(
      "insert into streak_badges (user_id, badge_key, year, quarter_index) values ($1, '2026-q1', 2026, 1)",
      [u],
    );
    await settle.query("commit");
    clean = true;
    await change;
  } finally {
    settle.release(!clean);
  }
  const [user] = await db.select().from(usersTable).where(eq(usersTable.id, u));
  assert(user.timezone === "America/Los_Angeles", `zone stored, got ${user.timezone}`);
  const s = await accountStreak(u);
  assert(iso(s.currentPeriodEnd) === "2026-01-12T08:00:00.000Z", `ends Monday 00:00 PST, got ${iso(s.currentPeriodEnd)}`);
}

/**
 * A save waits for a zone change in progress (its FOR SHARE on the user row), so
 * it uses the committed zone. A raw client holds the streak row, so the change
 * holds the user row while it waits; the save is sent then.
 */
async function saveWaitsForZoneChange() {
  const u = await newUser("c3-race-save");
  await recordSave(u, `save-${randomUUID()}`, SAVE_W1);
  const { id } = await accountStreak(u);
  const holder = await pool.connect();
  let clean = false;
  try {
    await holder.query("begin");
    await holder.query("select id from streaks where id = $1 for update", [id]);
    const change = setUserTimezone(u, "America/Los_Angeles", new Date("2026-01-08T12:00:00Z"));
    change.catch(() => {});
    await lockWaiters(1);
    // Monday 01:00 in Los Angeles: after the new end, still week 2 in UTC.
    const save = recordSave(u, `save-${randomUUID()}`, new Date("2026-01-12T09:00:00Z"));
    await lockWaiters(2);
    await holder.query("commit");
    clean = true;
    await change;
    await save;
  } finally {
    holder.release(!clean);
  }
  const s = await accountStreak(u);
  assert(s.currentCount === 2, `the save counts, got ${s.currentCount}`);
  // With the old zone the new period would start at 2026-01-12T00:00Z, inside the week just logged.
  assert(
    iso(s.currentPeriodStart) === "2026-01-12T08:00:00.000Z" && iso(s.currentPeriodEnd) === "2026-01-19T08:00:00.000Z",
    `the next local week, got ${iso(s.currentPeriodStart)} to ${iso(s.currentPeriodEnd)}`,
  );
}

/**
 * R9: a cadence change waits for a zone change in progress (both lock the user
 * row first), so it re-anchors in the committed zone. A raw client holds the
 * streak row, so the zone change holds the user row while it waits.
 */
async function cadenceChangeWaitsForZoneChange() {
  const u = await newUser("r3-r9-race-cadence");
  await recordSave(u, `save-${randomUUID()}`, SAVE_W1);
  const { id } = await accountStreak(u);
  const now = new Date("2026-01-08T12:00:00Z");
  const holder = await pool.connect();
  let clean = false;
  try {
    await holder.query("begin");
    await holder.query("select id from streaks where id = $1 for update", [id]);
    const change = setUserTimezone(u, "America/Los_Angeles", now);
    change.catch(() => {});
    await lockWaiters(1);
    const cadence = setStreakFrequency(u, "daily", now);
    cadence.catch(() => {});
    await lockWaiters(2);
    await holder.query("commit");
    clean = true;
    await change;
    await cadence;
  } finally {
    holder.release(!clean);
  }
  const [user] = await db.select().from(usersTable).where(eq(usersTable.id, u));
  assert(user.timezone === "America/Los_Angeles" && user.streakFrequency === "daily", `both stored, got ${user.timezone} ${user.streakFrequency}`);
  const s = await accountStreak(u);
  // January 8 in Los Angeles. With the zone read before the change committed it would be the UTC day.
  assert(
    iso(s.currentPeriodStart) === "2026-01-08T08:00:00.000Z" && iso(s.currentPeriodEnd) === "2026-01-09T08:00:00.000Z",
    `the Los Angeles day, got ${iso(s.currentPeriodStart)} to ${iso(s.currentPeriodEnd)}`,
  );
}

/**
 * R10: a close at once racing the job. A raw client holds the freeze row, as
 * grantFreezes does inside its transaction; the change, closing the saved week
 * at once (Nairobi at Sunday 22:00Z), takes the user and streak rows and then
 * waits for it, and so does the job's grant for this user. Neither deadlocks,
 * the week is logged once, and one freeze is granted. The job runs over every
 * user in the database (grants, settles, reminders), so another suite running
 * on the same database at the same time can see its rows change.
 */
async function closeAtOnceRacingJob() {
  const u = await newUser("r3-r10-race-job");
  await recordSave(u, `save-${randomUUID()}`, SAVE_W1);
  await db.insert(streakFreezesTable).values({ userId: u });
  const now = new Date("2026-01-11T22:00:00Z");
  const holder = await pool.connect();
  let clean = false;
  try {
    await holder.query("begin");
    await holder.query("select id from streak_freezes where user_id = $1 for update", [u]);
    const change = setUserTimezone(u, "Africa/Nairobi", now);
    change.catch(() => {});
    await lockWaiters(1);
    const job = evaluateStreaks(now);
    job.catch(() => {});
    await lockWaiters(2);
    await holder.query("commit");
    clean = true;
    await change;
    await job;
  } finally {
    holder.release(!clean);
  }
  const rows = await periodRows(u);
  assert(
    outcomes(rows) === "saved" && iso(rows[0].periodStart) === iso(W1) && iso(rows[0].periodEnd) === "2026-01-11T21:00:00.000Z",
    `W1 logged once, as kept, got ${JSON.stringify(rows)}`,
  );
  const s = await accountStreak(u);
  assert(
    iso(s.currentPeriodStart) === "2026-01-11T21:00:00.000Z" && iso(s.currentPeriodEnd) === "2026-01-18T21:00:00.000Z" &&
      s.currentCount === 1 && !s.currentPeriodSatisfied && s.status === "active",
    `the Nairobi week open, 1, got ${iso(s.currentPeriodStart)} to ${iso(s.currentPeriodEnd)} ${s.currentCount} ${s.status}`,
  );
  const f = await freezeRow(u);
  assert(f?.grantedTotal === 1 && f.usedTotal === 0 && f.balance === 1, `one freeze granted, none used, got ${JSON.stringify(f)}`);
}

async function main() {
  try {
    await smoke();
    await satisfiedPeriodCloses();
    await concurrentReads();
    await missedWithFreezeDue();
    await missedTwiceNoFreeze();
    await archivedStreakUntouched();
    await badgeAwardedOnce();
    await settleBeforeBreak();
    await settleBeforeCadenceChange();
    await westwardChange();
    await eastwardChange();
    await settleInOldZoneFirst();
    await sameZoneIsNoOp();
    await badgeNotReKeyed();
    await weeklyWestwardSundayEvening();
    await dailyWestwardEvening();
    await dailyEastwardAfterUtcBoundary();
    for (const c of ZONE_CASES) await zoneRule(c);
    await zoneChangeClosesPeriodOnBreak();
    await zoneChangesWithinOnePeriod(true);
    await zoneChangesWithinOnePeriod(false);
    await zoneChangeAfterClose();
    for (const c of PATH_CASES) await zonePath(c);
    await dailyAcrossSkippedMidnight("America/Havana", "2026-03-07", 3);
    await dailyAcrossSkippedMidnight("Atlantic/Azores", "2026-03-28", 3);
    await dailyAcrossSkippedMidnight("America/Santiago", "2026-09-02", 8);
    await closeAtOnceTwoSavesBothCount();
    await freezeCooldownInLocalDays({ label: "r3-r5-monthly-lagos", from: "UTC", to: "Africa/Lagos" });
    await freezeCooldownInLocalDays({ label: "r3-r5-monthly-london", from: "Europe/London" });
    await freezeCooldownWeeklyNairobi();
    await badgesAcrossZoneChange({ label: "r3-r6-west", from: "UTC", to: "America/Los_Angeles", first: "2026-q2", second: "2026-q3" });
    await badgesAcrossZoneChange({ label: "r3-r6-east", from: "UTC", to: "Pacific/Kiritimati", first: "2026-q2", second: "2026-q3" });
    await badgesAcrossZoneChange({ label: "r3-r6-la-tokyo", from: "America/Los_Angeles", to: "Asia/Tokyo", first: "2026-q1", second: "2026-q3" });
    await reviveDoesNotOverlap();
    await reminderMarkAfterChange();
    await stretchWithBreak({ label: "r3-r10-break-past-end", days: 14, statusAfter: "paused" });
    await stretchWithBreak({ label: "r3-r10-break-ends-inside", days: 6, statusAfter: "active" });
    await zoneChangeRacingSettle();
    await saveWaitsForZoneChange();
    await closeAtOnceRacingSave(true);
    await closeAtOnceRacingSave(false);
    await cadenceChangeWaitsForZoneChange();
    for (const c of SCRIPT_CASES) await zoneScript(c);
    await reviveAfterLaterSettle();
    await badgeAfterEarlierRun();
    await freezeCooldownLocalCalendar({
      label: "r4-cal3-5-lagos-late", zone: "Africa/Lagos", lastUsed: "2026-08-30T23:00:00Z",
      open: ["2026-11-15T23:00:00Z", "2026-11-22T23:00:00Z"], readAt: "2026-11-30T03:00:00Z", frozen: true,
    });
    await freezeCooldownLocalCalendar({
      label: "r4-cal3-5-london-early", zone: "Europe/London", lastUsed: "2026-08-16T23:00:00Z",
      open: ["2026-11-02T00:00:00Z", "2026-11-09T00:00:00Z"], readAt: "2026-11-16T03:00:00Z", frozen: false,
    });
    await freezeCooldownLocalCalendar({
      label: "r4-cal3-5-london-on-time", zone: "Europe/London", lastUsed: "2026-08-16T23:00:00Z",
      open: ["2026-11-09T00:00:00Z", "2026-11-16T00:00:00Z"], readAt: "2026-11-23T03:00:00Z", frozen: true,
    });
    // Last: the job runs over every streak in the database.
    await closeAtOnceRacingJob();
    console.log(
      `✅ streaks.e2e passed: account streak create, idempotent replay, per-period cap, advance, cadence change; settle before read, cadence change and break, once under concurrency; time zone change, no tail period, ${ZONE_CASES.length + 4} cases of the revised rule, ${PATH_CASES.length} paths of changes, skipped midnights, freeze cooldown, badges, revive, reminder mark, breaks; no deadlock, save waits for the change, a close at once racing a save and the job, cadence waits for the change; ${SCRIPT_CASES.length} round 4 scripts, a late save, a badge after an earlier run, the cooldown on the local calendar`,
    );
  } finally {
    await db.delete(usersTable).where(inArray(usersTable.id, userIds));
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("❌ streaks.e2e failed:", err);
    process.exit(1);
  });
