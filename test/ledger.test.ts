import { beforeEach, describe, expect, it } from "vitest";
import { db } from "@/lib/db";
import { userBalances, accountBalance, acct } from "@/lib/server/ledger";
import { createGoal, allocateToGoal, releaseFromGoal, listGoals } from "@/lib/server/goals";
import { deposit, withdraw } from "@/lib/server/deposits";
import { resetDb, createTestUser, fund } from "./helpers";

describe("ledger", () => {
  beforeEach(async () => {
    await resetDb();
  });

  it("keeps every transaction balanced (postings sum to zero)", async () => {
    const u = await createTestUser();
    await fund(u.id, 10_000);
    const txns = await db.transaction.findMany({ include: { postings: true } });
    expect(txns.length).toBeGreaterThan(0);
    for (const t of txns) {
      const sum = t.postings.reduce((s, p) => s + p.amountCents, 0);
      expect(sum).toBe(0);
    }
  });

  it("reflects deposits in the available balance", async () => {
    const u = await createTestUser();
    await deposit(u.id, 25_000);
    const b = await userBalances(u.id);
    expect(b.availableCents).toBe(25_000);
    expect(b.totalCents).toBe(25_000);
  });

  it("blocks deposits without KYC", async () => {
    const u = await createTestUser("No KYC", "unstarted");
    await expect(deposit(u.id, 5_000)).rejects.toThrow(/KYC/i);
  });

  it("allocates to a goal without changing the total, then releases", async () => {
    const u = await createTestUser();
    await fund(u.id, 100_000);
    const goal = await createGoal(u.id, {
      name: "Rent",
      targetCents: 200_000,
      deadline: new Date("2027-01-01"),
    });

    await allocateToGoal(u.id, goal.id, 40_000);
    let b = await userBalances(u.id);
    expect(b.availableCents).toBe(60_000);
    expect(b.allocatedCents).toBe(40_000);
    expect(b.totalCents).toBe(100_000); // total unchanged — goals are allocations

    const goals = await listGoals(u.id);
    expect(goals[0].savedCents).toBe(40_000);

    await releaseFromGoal(u.id, goal.id, 15_000);
    b = await userBalances(u.id);
    expect(b.availableCents).toBe(75_000);
    expect(b.allocatedCents).toBe(25_000);
  });

  it("rejects over-allocation and over-withdrawal", async () => {
    const u = await createTestUser();
    await fund(u.id, 5_000);
    const goal = await createGoal(u.id, {
      name: "Big",
      targetCents: 999_999,
      deadline: new Date("2027-01-01"),
    });
    await expect(allocateToGoal(u.id, goal.id, 10_000)).rejects.toThrow(/insufficient/i);
    await expect(withdraw(u.id, 10_000)).rejects.toThrow(/insufficient/i);
  });

  it("tracks the external account as the mirror of money in the system", async () => {
    const u = await createTestUser();
    await deposit(u.id, 30_000);
    // external is debited as money enters the system
    expect(await accountBalance(acct.external)).toBe(-30_000);
    expect(await accountBalance(acct.wallet(u.id))).toBe(30_000);
  });
});
