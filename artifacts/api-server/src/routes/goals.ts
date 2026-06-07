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
  DeleteGoalParams,
  DeleteGoalResponse,
} from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import { sendError } from "../lib/errors";
import { ObjectStorageService } from "../lib/objectStorage";
import {
  listGoals,
  getGoal,
  createGoal,
  allocateToGoal,
  releaseFromGoal,
  deleteGoal,
  type GoalHistoryItem,
} from "../lib/goals";

const router: IRouter = Router();

type GoalRow = {
  id: string;
  name: string;
  emoji: string;
  color: string;
  imageUrl: string | null;
  targetCents: number;
  savedCents: number;
  deadline: Date;
  frequency: string;
  autoSaveCents: number | null;
  createdAt: Date;
  onchain?: boolean;
  vaultAddress?: string | null;
  explorerUrl?: string | null;
  network?: string;
  feeBps?: number;
  history?: GoalHistoryItem[];
};

function goalToJson(g: GoalRow) {
  return {
    id: g.id,
    name: g.name,
    emoji: g.emoji,
    color: g.color,
    imageUrl: g.imageUrl ?? null,
    targetCents: g.targetCents,
    savedCents: g.savedCents,
    deadline: g.deadline.toISOString(),
    frequency: g.frequency,
    autoSaveCents: g.autoSaveCents ?? null,
    createdAt: g.createdAt.toISOString(),
    onchain: g.onchain ?? false,
    vaultAddress: g.vaultAddress ?? null,
    explorerUrl: g.explorerUrl ?? null,
    network: g.network ?? null,
    feeBps: g.feeBps ?? 0,
    history: g.history ?? [],
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
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  const imageUrl = parsed.data.imageUrl;
  if (imageUrl != null && imageUrl !== "") {
    // Only a real, allowlisted internal uploaded image may be stored — never an
    // arbitrary external URL (fetched in the user's browser: tracking / SSRF)
    // nor a disguised non-image upload.
    const usable = await new ObjectStorageService().isUsableImageObject(imageUrl);
    if (!usable) {
      res.status(400).json({ error: "Invalid goal image." });
      return;
    }
  }

  const goal = await createGoal(user.id, {
    name: parsed.data.name,
    emoji: parsed.data.emoji,
    color: parsed.data.color,
    targetCents: parsed.data.targetCents,
    deadline: new Date(parsed.data.deadline),
    frequency: parsed.data.frequency,
    autoSaveCents: parsed.data.autoSaveCents ?? null,
    imageUrl: imageUrl ?? null,
  });

  res.status(201).json(GetGoalResponse.parse(goalToJson(goal)));
});

router.get("/goals/:id", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = GetGoalParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: "Invalid request" });
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
    res.status(400).json({ error: "Invalid request" });
    return;
  }
  const parsed = AllocateToGoalBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  try {
    await allocateToGoal(user.id, params.data.id, parsed.data.amountCents);
  } catch (e) {
    sendError(res, e, "Allocation failed");
    return;
  }

  res.json(AllocateToGoalResponse.parse({ ok: true }));
});

router.post("/goals/:id/release", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = ReleaseFromGoalParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }
  const parsed = ReleaseFromGoalBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  try {
    const result = await releaseFromGoal(user.id, params.data.id, parsed.data.amountCents);
    res.json(
      ReleaseFromGoalResponse.parse({
        ok: true,
        grossCents: result.grossCents,
        netCents: result.netCents,
        feeCents: result.feeCents,
      }),
    );
  } catch (e) {
    sendError(res, e, "Release failed");
  }
});

router.post("/goals/:id/delete", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = DeleteGoalParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  try {
    const result = await deleteGoal(user.id, params.data.id);
    res.json(
      DeleteGoalResponse.parse({
        ok: true,
        withdrawnGrossCents: result.withdrawnGrossCents,
        withdrawnNetCents: result.withdrawnNetCents,
        feeCents: result.feeCents,
      }),
    );
  } catch (e) {
    sendError(res, e, "Delete failed");
  }
});

export default router;
