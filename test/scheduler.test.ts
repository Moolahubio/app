import { beforeEach, describe, expect, it } from "vitest";
import { db } from "@/lib/db";
import { userBalances } from "@/lib/server/ledger";
import { createGoal } from "@/lib/server/goals";
import { runAutoSaves, runContributionReminders } from "@/lib/server/scheduler";
import { resetDb, createTestUser, fund, makeActiveCircle } from "./helpers";

describe("scheduler", () => {
  beforeEach(async () => {
    await resetDb();
  });

  it("runs weekly auto-save once, then is idempotent within 7 days", async () => {
    const u = await createTestUser();
    await fund(u.id, 100_000);
    await createGoal(u.id, {
      name: "Auto",
      targetCents: 50_000,
      deadline: new Date("2027-01-01"),
      autoSaveCents: 8_000,
    });

    const r1 = await runAutoSaves();
    expect(r1.executed).toBe(1);
    expect(r1.movedCents).toBe(8_000);
    expect((await userBalances(u.id)).allocatedCents).toBe(8_000);

    const r2 = await runAutoSaves();
    expect(r2.executed).toBe(0);
    expect((await userBalances(u.id)).allocatedCents).toBe(8_000);
  });

  it("never auto-saves past the target", async () => {
    const u = await createTestUser();
    await fund(u.id, 100_000);
    await createGoal(u.id, {
      name: "Almost",
      targetCents: 5_000,
      deadline: new Date("2027-01-01"),
      autoSaveCents: 8_000, // larger than what's left to target
    });
    const r = await runAutoSaves();
    expect(r.movedCents).toBe(5_000);
    expect((await userBalances(u.id)).allocatedCents).toBe(5_000);
  });

  it("reminds members who haven't paid, once per round", async () => {
    const [u1, u2] = await Promise.all([createTestUser(), createTestUser()]);
    await makeActiveCircle([u1, u2], 5_000); // active round 1, no contributions yet

    const r1 = await runContributionReminders();
    expect(r1.sent).toBe(2);

    const r2 = await runContributionReminders();
    expect(r2.sent).toBe(0); // idempotent per round

    expect(await db.notification.count({ where: { type: "system" } })).toBe(2);
  });
});
