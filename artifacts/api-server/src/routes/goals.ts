import { Router, type IRouter } from "express";
import { eq, and } from "drizzle-orm";
import { db, goalsTable, walletsTable, transactionsTable } from "@workspace/db";
import {
  CreateGoalBody,
  GetGoalParams,
  AllocateToGoalParams,
  AllocateToGoalBody,
  ReleaseFromGoalParams,
  ReleaseFromGoalBody,
  ListGoalsResponse,
  GetGoalResponse,
} from "@workspace/api-zod";
import { requireAuth, getOrCreateWallet, type AuthRequest } from "../lib/auth";

const router: IRouter = Router();

function goalToJson(g: typeof goalsTable.$inferSelect) {
  return {
    id: g.id,
    name: g.name,
    emoji: g.emoji,
    color: g.color,
    targetCents: g.targetCents,
    savedCents: g.savedCents,
    deadline: g.deadline.toISOString(),
    autoSaveCents: g.autoSaveCents ?? null,
    createdAt: g.createdAt.toISOString(),
  };
}

router.get("/goals", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const goals = await db
    .select()
    .from(goalsTable)
    .where(eq(goalsTable.userId, user.id));

  res.json(ListGoalsResponse.parse(goals.map(goalToJson)));
});

router.post("/goals", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = CreateGoalBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: parsed.error.message });
    return;
  }

  const [goal] = await db
    .insert(goalsTable)
    .values({
      userId: user.id,
      name: parsed.data.name,
      emoji: parsed.data.emoji ?? "🎯",
      color: parsed.data.color ?? "#0E9E6E",
      targetCents: parsed.data.targetCents,
      deadline: new Date(parsed.data.deadline),
      autoSaveCents: parsed.data.autoSaveCents ?? null,
    })
    .returning();

  res.status(201).json(GetGoalResponse.parse(goalToJson(goal)));
});

router.get("/goals/:id", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = GetGoalParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: params.error.message });
    return;
  }

  const [goal] = await db
    .select()
    .from(goalsTable)
    .where(and(eq(goalsTable.id, params.data.id), eq(goalsTable.userId, user.id)));

  if (!goal) {
    res.status(404).json({ error: "Goal not found" });
    return;
  }

  res.json(GetGoalResponse.parse(goalToJson(goal)));
});

router.post("/goals/:id/allocate", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = AllocateToGoalParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: params.error.message });
    return;
  }
  const parsed = AllocateToGoalBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: parsed.error.message });
    return;
  }

  const wallet = await getOrCreateWallet(user.id);
  if (wallet.availableCents < parsed.data.amountCents) {
    res.status(400).json({ error: "Insufficient balance" });
    return;
  }

  const [goal] = await db
    .select()
    .from(goalsTable)
    .where(and(eq(goalsTable.id, params.data.id), eq(goalsTable.userId, user.id)));

  if (!goal) {
    res.status(404).json({ error: "Goal not found" });
    return;
  }

  await db
    .update(walletsTable)
    .set({
      availableCents: wallet.availableCents - parsed.data.amountCents,
      goalAllocatedCents: wallet.goalAllocatedCents + parsed.data.amountCents,
    })
    .where(eq(walletsTable.id, wallet.id));

  await db
    .update(goalsTable)
    .set({ savedCents: goal.savedCents + parsed.data.amountCents })
    .where(eq(goalsTable.id, goal.id));

  await db.insert(transactionsTable).values({
    userId: user.id,
    type: "goal_allocation",
    description: `Allocated to goal: ${goal.name}`,
    amountCents: parsed.data.amountCents,
    onchainStatus: "none",
    referenceId: goal.id,
    referenceType: "goal",
  });

  res.json({ ok: true });
});

router.post("/goals/:id/release", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = ReleaseFromGoalParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: params.error.message });
    return;
  }
  const parsed = ReleaseFromGoalBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: parsed.error.message });
    return;
  }

  const [goal] = await db
    .select()
    .from(goalsTable)
    .where(and(eq(goalsTable.id, params.data.id), eq(goalsTable.userId, user.id)));

  if (!goal) {
    res.status(404).json({ error: "Goal not found" });
    return;
  }

  if (goal.savedCents < parsed.data.amountCents) {
    res.status(400).json({ error: "Cannot release more than saved" });
    return;
  }

  const wallet = await getOrCreateWallet(user.id);

  await db
    .update(walletsTable)
    .set({
      availableCents: wallet.availableCents + parsed.data.amountCents,
      goalAllocatedCents: wallet.goalAllocatedCents - parsed.data.amountCents,
    })
    .where(eq(walletsTable.id, wallet.id));

  await db
    .update(goalsTable)
    .set({ savedCents: goal.savedCents - parsed.data.amountCents })
    .where(eq(goalsTable.id, goal.id));

  await db.insert(transactionsTable).values({
    userId: user.id,
    type: "goal_release",
    description: `Released from goal: ${goal.name}`,
    amountCents: parsed.data.amountCents,
    onchainStatus: "none",
    referenceId: goal.id,
    referenceType: "goal",
  });

  res.json({ ok: true });
});

export default router;
