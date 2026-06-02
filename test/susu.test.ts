import { beforeEach, describe, expect, it } from "vitest";
import { db } from "@/lib/db";
import { userBalances } from "@/lib/server/ledger";
import {
  contribute,
  inviteToCircle,
  acceptInvite,
  startCircle,
} from "@/lib/server/circles";
import { resetDb, createTestUser, fund, makeActiveCircle } from "./helpers";

describe("susu circles", () => {
  beforeEach(async () => {
    await resetDb();
  });

  it("pays the round's recipient once everyone contributes, then advances", async () => {
    const [u1, u2, u3] = await Promise.all([
      createTestUser("A"),
      createTestUser("B"),
      createTestUser("C"),
    ]);
    await Promise.all([fund(u1.id, 50_000), fund(u2.id, 50_000), fund(u3.id, 50_000)]);
    const c = await makeActiveCircle([u1, u2, u3], 10_000);

    await contribute(u1.id, c.id);
    await contribute(u2.id, c.id);
    await contribute(u3.id, c.id); // completes round 1 -> payout to position 1 (u1)

    const b1 = await userBalances(u1.id);
    const b2 = await userBalances(u2.id);
    const b3 = await userBalances(u3.id);
    // u1: -10k contribution + 30k pot = +20k
    expect(b1.availableCents).toBe(70_000);
    expect(b2.availableCents).toBe(40_000);
    expect(b3.availableCents).toBe(40_000);

    const fresh = await db.circle.findUnique({ where: { id: c.id } });
    expect(fresh?.currentRound).toBe(2);
    const m1 = await db.circleMember.findFirst({ where: { circleId: c.id, userId: u1.id } });
    expect(m1?.paidOut).toBe(true);

    // recipient got a payout notification
    const payout = await db.notification.count({ where: { userId: u1.id, type: "payout" } });
    expect(payout).toBe(1);
  });

  it("rejects a second contribution in the same round", async () => {
    const [u1, u2] = await Promise.all([createTestUser(), createTestUser()]);
    await Promise.all([fund(u1.id, 50_000), fund(u2.id, 50_000)]);
    const c = await makeActiveCircle([u1, u2], 10_000);
    await contribute(u1.id, c.id);
    await expect(contribute(u1.id, c.id)).rejects.toThrow(/already/i);
  });

  it("rejects a contribution with insufficient balance", async () => {
    const [u1, u2] = await Promise.all([createTestUser(), createTestUser()]);
    await fund(u1.id, 1_000); // not enough for a 10k round
    const c = await makeActiveCircle([u1, u2], 10_000);
    await expect(contribute(u1.id, c.id)).rejects.toThrow(/insufficient/i);
  });

  it("invite -> accept -> start activates the circle and notifies", async () => {
    const owner = await createTestUser("Owner");
    const friend = await createTestUser("Friend");
    const c = await db.circle.create({
      data: {
        name: "Forming",
        status: "forming",
        contributionCents: 5_000,
        frequency: "weekly",
        totalRounds: 1,
        currentRound: 0,
        startDate: new Date(),
        createdById: owner.id,
        members: { create: { userId: owner.id, position: 1, payoutRound: 1 } },
      },
    });

    await inviteToCircle(owner.id, c.id, friend.email);
    const invite = await db.circleInvite.findFirst({ where: { circleId: c.id } });
    expect(invite?.status).toBe("pending");
    // friend received an in-app invite notification
    expect(await db.notification.count({ where: { userId: friend.id, type: "invite" } })).toBe(1);

    await acceptInvite(friend.id, friend.email, invite!.id);
    expect(await db.circleMember.count({ where: { circleId: c.id } })).toBe(2);

    await startCircle(owner.id, c.id);
    const fresh = await db.circle.findUnique({ where: { id: c.id } });
    expect(fresh?.status).toBe("active");
    expect(fresh?.currentRound).toBe(1);
    expect(fresh?.totalRounds).toBe(2);
  });

  it("won't start a circle with fewer than two members", async () => {
    const owner = await createTestUser("Solo");
    const c = await db.circle.create({
      data: {
        name: "Solo",
        status: "forming",
        contributionCents: 5_000,
        frequency: "weekly",
        totalRounds: 1,
        currentRound: 0,
        startDate: new Date(),
        createdById: owner.id,
        members: { create: { userId: owner.id, position: 1, payoutRound: 1 } },
      },
    });
    await expect(startCircle(owner.id, c.id)).rejects.toThrow(/at least one more/i);
  });
});
