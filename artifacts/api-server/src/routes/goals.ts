import { Router, type IRouter } from "express";
import {
  CreateGoalBody,
  GetGoalParams,
  AllocateToGoalParams,
  AllocateToGoalBody,
  ReleaseFromGoalParams,
  ReleaseFromGoalBody,
  ListGoalsResponse,
  GetGoalResponse,
  AllocateToGoalResponse,
  ReleaseFromGoalResponse,
} from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import {
  listGoals,
  getGoal,
  createGoal,
  allocateToGoal,
  releaseFromGoal,
} from "../lib/goals";

const router: IRouter = Router();

type GoalRow = {
  id: string;
  name: string;
  emoji: string;
  color: string;
  targetCents: number;
  savedCents: number;
  deadline: Date;
  autoSaveCents: number | null;
  createdAt: Date;
};

function goalToJson(g: GoalRow) {
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
  const goals = await listGoals(user.id);
  res.json(ListGoalsResponse.parse(goals.map(goalToJson)));
});

router.post("/goals", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = CreateGoalBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: parsed.error.message });
    return;
  }

  const goal = await createGoal(user.id, {
    name: parsed.data.name,
    emoji: parsed.data.emoji,
    color: parsed.data.color,
    targetCents: parsed.data.targetCents,
    deadline: new Date(parsed.data.deadline),
    autoSaveCents: parsed.data.autoSaveCents ?? null,
  });

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

  const goal = await getGoal(user.id, params.data.id);
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

  try {
    await allocateToGoal(user.id, params.data.id, parsed.data.amountCents);
  } catch (e) {
    res.status(400).json({ error: e instanceof Error ? e.message : "Allocation failed" });
    return;
  }

  res.json(AllocateToGoalResponse.parse({ ok: true }));
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

  try {
    await releaseFromGoal(user.id, params.data.id, parsed.data.amountCents);
  } catch (e) {
    res.status(400).json({ error: e instanceof Error ? e.message : "Release failed" });
    return;
  }

  res.json(ReleaseFromGoalResponse.parse({ ok: true }));
});

export default router;
