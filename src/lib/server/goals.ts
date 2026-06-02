import "server-only";
import { db } from "@/lib/db";
import { acct, transfer, goalBalances } from "./ledger";

export async function listGoals(userId: string) {
  const [goals, balances] = await Promise.all([
    db.goal.findMany({ where: { userId }, orderBy: { createdAt: "asc" } }),
    goalBalances(userId),
  ]);
  return goals.map((g) => ({ ...g, savedCents: balances[g.id] ?? 0 }));
}

export async function getGoal(userId: string, goalId: string) {
  const goal = await db.goal.findFirst({ where: { id: goalId, userId } });
  if (!goal) return null;
  const balances = await goalBalances(userId);
  return { ...goal, savedCents: balances[goalId] ?? 0 };
}

export async function createGoal(
  userId: string,
  input: {
    name: string;
    emoji?: string;
    targetCents: number;
    deadline: Date;
    autoSaveCents?: number | null;
    color?: string;
  },
) {
  return db.goal.create({
    data: {
      userId,
      name: input.name,
      emoji: input.emoji || "🎯",
      targetCents: input.targetCents,
      deadline: input.deadline,
      autoSaveCents: input.autoSaveCents ?? null,
      color: input.color || "jade",
    },
  });
}

/** Earmark available wallet funds into a goal allocation (no on-chain move). */
export async function allocateToGoal(userId: string, goalId: string, amountCents: number) {
  const goal = await db.goal.findFirst({ where: { id: goalId, userId } });
  if (!goal) throw new Error("Goal not found");
  const available = await db.posting.aggregate({
    _sum: { amountCents: true },
    where: { account: { key: acct.wallet(userId) } },
  });
  if ((available._sum.amountCents ?? 0) < amountCents) {
    throw new Error("Insufficient available balance");
  }
  return transfer({
    type: "goal_allocate",
    description: `Allocation → ${goal.name}`,
    userId,
    fromKey: acct.wallet(userId),
    toKey: acct.goal(goalId),
    amountCents,
  });
}

/** Release funds from a goal back to the available wallet balance. */
export async function releaseFromGoal(userId: string, goalId: string, amountCents: number) {
  const goal = await db.goal.findFirst({ where: { id: goalId, userId } });
  if (!goal) throw new Error("Goal not found");
  const balances = await goalBalances(userId);
  if ((balances[goalId] ?? 0) < amountCents) throw new Error("Insufficient goal balance");
  return transfer({
    type: "goal_release",
    description: `Released from ${goal.name}`,
    userId,
    fromKey: acct.goal(goalId),
    toKey: acct.wallet(userId),
    amountCents,
  });
}
