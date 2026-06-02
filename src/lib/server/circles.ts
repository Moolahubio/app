import "server-only";
import { db } from "@/lib/db";
import { acct, transfer } from "./ledger";
import { onchainEnabled, sendPayment } from "./stellar";
import { getSigningSecret } from "./wallet";
import { toMeta } from "./deposits";

const INTERVAL_DAYS: Record<string, number> = { weekly: 7, biweekly: 14, monthly: 30 };

function addInterval(start: Date, frequency: string, rounds: number) {
  const d = new Date(start);
  d.setDate(d.getDate() + INTERVAL_DAYS[frequency] * rounds);
  return d;
}

export type MemberState = "paid" | "current" | "upcoming";

function memberState(payoutRound: number, currentRound: number, paidOut: boolean): MemberState {
  if (paidOut || payoutRound < currentRound) return "paid";
  if (payoutRound === currentRound) return "current";
  return "upcoming";
}

export async function listCirclesForUser(userId: string) {
  const circles = await db.circle.findMany({
    where: { members: { some: { userId } } },
    include: { members: { include: { user: true } }, contributions: true },
    orderBy: { createdAt: "desc" },
  });
  return circles.map((c) => {
    const memberCount = c.members.length;
    return {
      id: c.id,
      name: c.name,
      status: c.status,
      frequency: c.frequency,
      contributionCents: c.contributionCents,
      potCents: c.contributionCents * memberCount,
      memberCount,
      totalRounds: c.totalRounds,
      currentRound: c.currentRound,
      paidOutCount: c.members.filter((m) => m.paidOut).length,
      members: c.members.map((m) => ({ name: m.user.name, isYou: m.userId === userId })),
    };
  });
}

export async function getCircleDetail(userId: string, circleId: string) {
  const c = await db.circle.findFirst({
    where: { id: circleId, members: { some: { userId } } },
    include: {
      members: { include: { user: true }, orderBy: { position: "asc" } },
      contributions: { where: { userId }, orderBy: { round: "asc" } },
    },
  });
  if (!c) return null;
  const memberCount = c.members.length;
  const me = c.members.find((m) => m.userId === userId);
  const contributedThisRound = c.contributions.some((x) => x.round === c.currentRound);

  return {
    id: c.id,
    name: c.name,
    status: c.status,
    frequency: c.frequency,
    contributionCents: c.contributionCents,
    potCents: c.contributionCents * memberCount,
    memberCount,
    totalRounds: c.totalRounds,
    currentRound: c.currentRound,
    contractAddress: c.contractAddress,
    nextContributionDate: addInterval(c.startDate, c.frequency, Math.max(0, c.currentRound - 1)),
    myPosition: me?.position ?? null,
    contributedThisRound,
    canContribute: c.status === "active" && !contributedThisRound && !!me,
    members: c.members.map((m) => ({
      name: m.user.name,
      position: m.position,
      payoutRound: m.payoutRound,
      isYou: m.userId === userId,
      paidOut: m.paidOut,
      state: memberState(m.payoutRound, c.currentRound, m.paidOut),
      payoutDate: addInterval(c.startDate, c.frequency, m.payoutRound - 1),
    })),
    history: c.contributions.map((h) => ({
      id: h.id,
      round: h.round,
      amountCents: h.amountCents,
      txHash: h.txHash,
      status: h.status,
      createdAt: h.createdAt,
    })),
  };
}

/** Make this round's contribution; trigger the payout when the round fills. */
export async function contribute(userId: string, circleId: string) {
  const circle = await db.circle.findFirst({
    where: { id: circleId, members: { some: { userId } } },
    include: { members: true },
  });
  if (!circle) throw new Error("Circle not found");
  if (circle.status !== "active") throw new Error("Circle is not active");
  const round = circle.currentRound;

  const already = await db.contribution.findFirst({ where: { circleId, userId, round } });
  if (already) throw new Error("You've already contributed this round");

  const available = await db.posting.aggregate({
    _sum: { amountCents: true },
    where: { account: { key: acct.wallet(userId) } },
  });
  if ((available._sum.amountCents ?? 0) < circle.contributionCents) {
    throw new Error("Insufficient available balance");
  }

  // On-chain: member → platform escrow (distributor stands in for the Soroban pot).
  let meta = {};
  if (onchainEnabled()) {
    const secret = await getSigningSecret(userId);
    const distributor = process.env.STELLAR_DISTRIBUTOR_PUBLIC;
    if (secret && distributor) {
      const r = await sendPayment({
        fromSecret: secret,
        toPublicKey: distributor,
        amountCents: circle.contributionCents,
        memo: `susu:${circleId}`,
      });
      meta = toMeta(r);
    }
  }

  const txn = await transfer({
    type: "contribution",
    description: `${circle.name} · round ${round}`,
    userId,
    fromKey: acct.wallet(userId),
    toKey: acct.pool(circleId),
    amountCents: circle.contributionCents,
    onchain: meta,
  });

  await db.contribution.create({
    data: {
      circleId,
      userId,
      round,
      amountCents: circle.contributionCents,
      txHash: (meta as { txHash?: string }).txHash ?? null,
      status: "confirmed",
    },
  });

  await maybeProcessPayout(circleId, round);
  return txn;
}

/** If every member has contributed this round, pay the round's recipient. */
async function maybeProcessPayout(circleId: string, round: number) {
  const circle = await db.circle.findUnique({
    where: { id: circleId },
    include: { members: { include: { user: { include: { wallet: true } } } } },
  });
  if (!circle) return;
  const count = await db.contribution.count({ where: { circleId, round } });
  if (count < circle.members.length) return;

  const recipient = circle.members.find((m) => m.payoutRound === round);
  if (recipient && !recipient.paidOut) {
    const potCents = circle.contributionCents * circle.members.length;

    let meta = {};
    if (onchainEnabled() && recipient.user.wallet) {
      const r = await sendPayment({
        fromSecret: process.env.STELLAR_DISTRIBUTOR_SECRET!,
        toPublicKey: recipient.user.wallet.stellarPublicKey,
        amountCents: potCents,
        memo: `payout:${circleId}`,
      });
      meta = toMeta(r);
    }
    await transfer({
      type: "payout",
      description: `${circle.name} · round ${round} payout`,
      userId: recipient.userId,
      fromKey: acct.pool(circleId),
      toKey: acct.wallet(recipient.userId),
      amountCents: potCents,
      onchain: meta,
    });
    await db.circleMember.update({ where: { id: recipient.id }, data: { paidOut: true } });
  }

  // Advance the round (or complete the circle).
  const nextRound = round + 1;
  await db.circle.update({
    where: { id: circleId },
    data:
      nextRound > circle.totalRounds
        ? { status: "completed", currentRound: circle.totalRounds }
        : { currentRound: nextRound },
  });
}
