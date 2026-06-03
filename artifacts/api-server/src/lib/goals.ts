import { eq, and, asc } from "drizzle-orm";
import { db, goalsTable } from "@workspace/db";
import { acct, transfer, accountBalance, goalBalances } from "./ledger";
import { notify } from "./notifications";
import { formatMoney } from "./money";

export async function listGoals(userId: string) {
  const [goals, balances] = await Promise.all([
    db.select().from(goalsTable).where(eq(goalsTable.userId, userId)).orderBy(asc(goalsTable.createdAt)),
    goalBalances(userId),
  ]);
  return goals.map((g) => ({ ...g, savedCents: balances[g.id] ?? 0 }));
}

export async function getGoal(userId: string, goalId: string) {
  const [goal] = await db
    .select()
    .from(goalsTable)
    .where(and(eq(goalsTable.id, goalId), eq(goalsTable.userId, userId)));
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
    frequency?: string;
    autoSaveCents?: number | null;
    color?: string;
    imageUrl?: string | null;
  },
) {
  const [goal] = await db
    .insert(goalsTable)
    .values({
      userId,
      name: input.name,
      emoji: input.emoji || "🎯",
      targetCents: input.targetCents,
      deadline: input.deadline,
      frequency: input.frequency || "weekly",
      autoSaveCents: input.autoSaveCents ?? null,
      color: input.color || "jade",
      imageUrl: input.imageUrl ?? null,
    })
    .returning();
  return { ...goal, savedCents: 0 };
}

/** Earmark available wallet funds into a goal allocation (no on-chain move). */
export async function allocateToGoal(userId: string, goalId: string, amountCents: number) {
  const [goal] = await db
    .select()
    .from(goalsTable)
    .where(and(eq(goalsTable.id, goalId), eq(goalsTable.userId, userId)));
  if (!goal) throw new Error("Goal not found");
  if ((await accountBalance(acct.wallet(userId))) < amountCents) {
    throw new Error("Insufficient available balance");
  }
  const txn = await transfer({
    type: "goal_allocate",
    description: `Allocation → ${goal.name}`,
    userId,
    fromKey: acct.wallet(userId),
    toKey: acct.goal(goalId),
    amountCents,
    requireSufficientFrom: true,
  });
  await notify(userId, {
    type: "goal",
    title: `Added to ${goal.name}`,
    body: `${formatMoney(amountCents)} ${goal.emoji} moved into your ${goal.name} goal.`,
    link: `/goals/${goalId}`,
  });
  return txn;
}

/** Release funds from a goal back to the available wallet balance. */
export async function releaseFromGoal(userId: string, goalId: string, amountCents: number) {
  const [goal] = await db
    .select()
    .from(goalsTable)
    .where(and(eq(goalsTable.id, goalId), eq(goalsTable.userId, userId)));
  if (!goal) throw new Error("Goal not found");
  const balances = await goalBalances(userId);
  if ((balances[goalId] ?? 0) < amountCents) throw new Error("Insufficient goal balance");
  const txn = await transfer({
    type: "goal_release",
    description: `Released from ${goal.name}`,
    userId,
    fromKey: acct.goal(goalId),
    toKey: acct.wallet(userId),
    amountCents,
    requireSufficientFrom: true,
  });
  await notify(userId, {
    type: "goal",
    title: `Withdrawn from ${goal.name}`,
    body: `${formatMoney(amountCents)} returned to your available balance.`,
    link: `/goals/${goalId}`,
  });
  return txn;
}
