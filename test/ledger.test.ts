import { beforeEach, describe, expect, it } from "vitest";
import { Keypair } from "@stellar/stellar-sdk";
import { db } from "@/lib/db";
import { userBalances, accountBalance, acct } from "@/lib/server/ledger";
import { createGoal, allocateToGoal, releaseFromGoal, listGoals } from "@/lib/server/goals";
import { faucetDeposit, withdrawToAddress } from "@/lib/server/deposits";
import { resetDb, createTestUser, fund } from "./helpers";

const VALID_DEST = Keypair.random().publicKey();

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

  it("credits the available balance on a (faucet) deposit — no KYC needed", async () => {
    const u = await createTestUser("No KYC", "unstarted");
    await faucetDeposit(u.id, 25_000);
    const b = await userBalances(u.id);
    expect(b.availableCents).toBe(25_000);
    expect(b.totalCents).toBe(25_000);
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
    await expect(withdrawToAddress(u.id, 10_000, VALID_DEST)).rejects.toThrow(/insufficient/i);
  });

  it("rejects a withdrawal to an invalid Stellar address", async () => {
    const u = await createTestUser();
    await fund(u.id, 50_000);
    await expect(withdrawToAddress(u.id, 10_000, "not-an-address")).rejects.toThrow(/valid Stellar/i);
  });

  it("debits available on a valid withdrawal", async () => {
    const u = await createTestUser();
    await fund(u.id, 50_000);
    await withdrawToAddress(u.id, 20_000, VALID_DEST);
    expect((await userBalances(u.id)).availableCents).toBe(30_000);
  });

  it("tracks the external account as the mirror of money in the system", async () => {
    const u = await createTestUser();
    await faucetDeposit(u.id, 30_000);
    expect(await accountBalance(acct.external)).toBe(-30_000);
    expect(await accountBalance(acct.wallet(u.id))).toBe(30_000);
  });
});
