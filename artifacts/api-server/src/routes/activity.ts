import { Router, type IRouter } from "express";
import { ListActivityQueryParams, ListActivityResponse } from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import { userActivity } from "../lib/ledger";

const router: IRouter = Router();

router.get("/activity", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const queryParams = ListActivityQueryParams.safeParse(req.query);
  const limit = queryParams.success ? (queryParams.data.limit ?? 20) : 20;

  const rows = await userActivity(user.id, limit);
  const result = rows.map((t) => ({
    id: t.id,
    type: t.type,
    description: t.description,
    amountCents: t.amountCents,
    txHash: t.txHash ?? null,
    onchainStatus: t.onchainStatus,
    createdAt: t.createdAt.toISOString(),
  }));

  res.json(ListActivityResponse.parse(result));
});

export default router;
