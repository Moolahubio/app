/**
 * Streak engine smoke test against the real DB.
 * Run: pnpm --filter @workspace/api-server run test:streaks
 *
 * Validates the new streak tables line up with the engine: a save creates a
 * streak, the same save reference is idempotent (no farming a streak by
 * replaying one save), a second distinct save in a later period advances the
 * count, and the read projection returns a coherent overview. Cleans up after
 * itself in a finally block.
 */
import { randomUUID } from "node:crypto";
import { db, usersTable } from "@workspace/db";
import { eq } from "drizzle-orm";
import { recordSave, getStreakOverview, setStreakFrequency } from "./streaks";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(`ASSERT FAILED: ${msg}`);
}

async function main() {
  const userId = randomUUID();

  // Default weekly cadence; UTC keeps calendar-week math deterministic.
  await db.insert(usersTable).values({
    id: userId,
    name: "Streak Test",
    email: `streak-${userId}@test.local`,
    timezone: "UTC",
  });

  try {
    const t0 = new Date("2026-01-05T12:00:00Z"); // a Monday (start of an ISO week)
    const refA = `save-${randomUUID()}`;

    const heroCount = async (): Promise<number> => {
      const ov = await getStreakOverview(userId);
      assert(ov.hero, "hero should exist");
      return ov.hero.count;
    };

    // First save (any deposit) lights the single account streak at 1.
    await recordSave(userId, refA, t0);
    let ov = await getStreakOverview(userId);
    assert(ov.hero, "hero should exist after first save");
    assert(ov.hero.count === 1, `expected count 1, got ${ov.hero.count}`);
    assert(ov.frequency === "weekly", `default frequency should be weekly, got ${ov.frequency}`);
    assert(ov.currentPeriodSatisfied, "current period should be satisfied");
    assert(ov.commitments.length === 0, "per-commitment streaks are retired (empty list)");

    // Replaying the SAME save reference must NOT advance (idempotent — no farming
    // a streak from one deposit).
    await recordSave(userId, refA, t0);
    assert((await heroCount()) === 1, "replay must stay at 1");

    // A second deposit in the SAME week must not advance either (once per period).
    await recordSave(userId, `save-${randomUUID()}`, new Date("2026-01-07T09:00:00Z"));
    assert((await heroCount()) === 1, "same-week second save must stay at 1");

    // A distinct save in the NEXT calendar week advances the streak to 2.
    const t1 = new Date("2026-01-12T12:00:00Z"); // the following Monday
    await recordSave(userId, `save-${randomUUID()}`, t1);
    assert((await heroCount()) === 2, "expected count 2 after next-week save");

    ov = await getStreakOverview(userId);
    assert(ov.lifetimeBest >= 2, `lifetimeBest should be >= 2, got ${ov.lifetimeBest}`);
    assert(ov.canChangeFrequency, "frequency should be changeable before any change");

    // Switching cadence keeps the count and consumes the annual allowance.
    ov = await setStreakFrequency(userId, "daily");
    assert(ov.frequency === "daily", `frequency should now be daily, got ${ov.frequency}`);
    assert(ov.hero && ov.hero.count === 2, "count must be preserved across a cadence change");
    assert(!ov.canChangeFrequency, "second change in the same year should be blocked");

    let blocked = false;
    try {
      await setStreakFrequency(userId, "monthly");
    } catch {
      blocked = true;
    }
    assert(blocked, "changing frequency twice in one calendar year must throw");

    console.log("✅ streaks.e2e passed: account streak create, idempotent replay, per-period cap, advance, cadence change");
  } finally {
    await db.delete(usersTable).where(eq(usersTable.id, userId));
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("❌ streaks.e2e failed:", err);
    process.exit(1);
  });
