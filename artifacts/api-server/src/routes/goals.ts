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
  DeleteGoalBody,
  DeleteGoalResponse,
  ConfirmGoalDepositParams,
  ConfirmGoalDepositBody,
  ConfirmGoalDepositResponse,
  ConfirmGoalReleaseParams,
  ConfirmGoalReleaseBody,
  ConfirmGoalReleaseResponse,
} from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import { requireAllowedOrigin, requireJsonAndAllowedOrigin } from "../lib/origins";
import { sendError } from "../lib/errors";
import { ObjectStorageService } from "../lib/objectStorage";
import { verifyStepUp } from "../lib/stepUp";
import {
  listGoals,
  getGoal,
  createGoal,
  allocateToGoal,
  releaseFromGoal,
  deleteGoal,
  confirmClientGoalDeposit,
  confirmClientGoalRelease,
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

router.post("/goals", requireJsonAndAllowedOrigin, requireAuth, async (req, res): Promise<void> => {
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
    const objectStorage = new ObjectStorageService();
    const usable = await objectStorage.isUsableImageObject(imageUrl);
    if (!usable) {
      res.status(400).json({ error: "Invalid goal image." });
      return;
    }
    // Goals are personal: the image is only ever displayed back to its owner, so
    // lock the object to the owner. Until bound here an object has no ACL policy
    // and the serving route refuses to read it. Claiming fails if the object is
    // already owned by someone else, preventing object takeover by path.
    const claimed = await objectStorage.claimObjectEntityForOwner(
      imageUrl,
      user.id,
      "private",
    );
    if (!claimed) {
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

router.post("/goals/:id/allocate", requireJsonAndAllowedOrigin, requireAuth, async (req, res): Promise<void> => {
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

// Releasing/withdrawing goal savings moves real funds out of the on-chain
// vault. A stolen session cookie alone must never be enough — require fresh
// step-up proof of an existing login factor first, same as a wallet withdrawal.
router.post("/goals/:id/release", requireJsonAndAllowedOrigin, requireAuth, async (req, res): Promise<void> => {
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

  const stepUp = await verifyStepUp(user, parsed.data);
  if (!stepUp.ok) {
    res.status(stepUp.status).json({ error: stepUp.error });
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

// Deleting a goal auto-withdraws its full balance (net of fee) back to the
// wallet. A stolen session cookie alone must never be enough to trigger that
// fund movement — require fresh step-up proof first, same as any withdrawal.
router.post("/goals/:id/delete", requireJsonAndAllowedOrigin, requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = DeleteGoalParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }
  const parsed = DeleteGoalBody.safeParse(req.body ?? {});
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  const stepUp = await verifyStepUp(user, parsed.data);
  if (!stepUp.ok) {
    res.status(stepUp.status).json({ error: stepUp.error });
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

// Confirm a client-signed (non-custodial) goal deposit after the user's own
// device broadcast it. No step-up: the user's device key already authorized the
// move and re-gating an already-settled transfer could only strand it. Server-
// custody wallets are refused inside confirmClientGoalDeposit and use /allocate.
router.post(
  "/goals/:id/deposit/submitted",
  requireJsonAndAllowedOrigin,
  requireAuth,
  async (req, res): Promise<void> => {
    const user = (req as AuthRequest).user;
    const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
    const params = ConfirmGoalDepositParams.safeParse({ id: rawId });
    if (!params.success) {
      res.status(400).json({ error: "Invalid request" });
      return;
    }
    const parsed = ConfirmGoalDepositBody.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "Invalid request" });
      return;
    }

    try {
      await confirmClientGoalDeposit(
        user.id,
        params.data.id,
        parsed.data.txHash,
        parsed.data.amountCents,
      );
    } catch (e) {
      sendError(res, e, "Couldn't confirm deposit");
      return;
    }

    res.json(ConfirmGoalDepositResponse.parse({ ok: true }));
  },
);

// Confirm a client-signed (non-custodial) goal withdrawal after broadcast. Like
// the deposit path, no step-up — the user's own device key already signed the
// on-chain withdraw. Server-custody wallets use the step-up-gated /release path.
router.post(
  "/goals/:id/release/submitted",
  requireJsonAndAllowedOrigin,
  requireAuth,
  async (req, res): Promise<void> => {
    const user = (req as AuthRequest).user;
    const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
    const params = ConfirmGoalReleaseParams.safeParse({ id: rawId });
    if (!params.success) {
      res.status(400).json({ error: "Invalid request" });
      return;
    }
    const parsed = ConfirmGoalReleaseBody.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "Invalid request" });
      return;
    }

    try {
      const result = await confirmClientGoalRelease(
        user.id,
        params.data.id,
        parsed.data.txHash,
        parsed.data.amountCents,
      );
      res.json(
        ConfirmGoalReleaseResponse.parse({
          ok: true,
          grossCents: result.grossCents,
          netCents: result.netCents,
          feeCents: result.feeCents,
        }),
      );
    } catch (e) {
      sendError(res, e, "Couldn't confirm withdrawal");
    }
  },
);

export default router;
