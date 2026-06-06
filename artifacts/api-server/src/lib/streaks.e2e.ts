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
import { recordSave, getStreakOverview, type Commitment } from "./streaks";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(`ASSERT FAILED: ${msg}`);
}

async function main() {
  const userId = randomUUID();
  const commitment: Commitment = { type: "goal", id: randomUUID(), frequency: "weekly" };

  await db.insert(usersTable).values({
    id: userId,
    name: "Streak Test",
    email: `streak-${userId}@test.local`,
  });

  try {
    const t0 = new Date("2026-01-05T12:00:00Z"); // a Monday
    const refA = `save-${randomUUID()}`;

    // First save creates an active streak of 1.
    await recordSave(userId, commitment, refA, t0);
    const heroCount = async (): Promise<number> => {
      const ov = await getStreakOverview(userId);
      assert(ov.hero, "hero should exist");
      return ov.hero.count;
    };

    let ov = await getStreakOverview(userId);
    assert(ov.hero, "hero should exist after first save");
    assert(ov.hero.count === 1, `expected count 1, got ${ov.hero.count}`);
    assert(ov.commitments.length === 1, "one commitment expected");
    assert(ov.commitments[0].currentPeriodSatisfied, "current period should be satisfied");

    // Replaying the SAME save reference must NOT advance the streak (idempotent;
    // prevents farming a streak from one deposit).
    await recordSave(userId, commitment, refA, t0);
    const afterReplay = await heroCount();
    assert(afterReplay === 1, `replay must stay at 1, got ${afterReplay}`);

    // A distinct save in the NEXT week advances the streak to 2.
    const t1 = new Date("2026-01-12T12:00:00Z");
    await recordSave(userId, commitment, `save-${randomUUID()}`, t1);
    const afterNextWeek = await heroCount();
    assert(afterNextWeek === 2, `expected count 2 after next-week save, got ${afterNextWeek}`);
    ov = await getStreakOverview(userId);
    assert(ov.lifetimeBest >= 2, `lifetimeBest should be >= 2, got ${ov.lifetimeBest}`);

    console.log("✅ streaks.e2e passed: create, idempotent replay, period advance, read projection");
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
