import { Router, type IRouter } from "express";
import { eq, desc } from "drizzle-orm";
import { db, transactionsTable } from "@workspace/db";
import { ListActivityQueryParams, ListActivityResponse } from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";

const router: IRouter = Router();

router.get("/activity", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const queryParams = ListActivityQueryParams.safeParse(req.query);
  const limit = queryParams.success ? (queryParams.data.limit ?? 20) : 20;

  const txs = await db
    .select()
    .from(transactionsTable)
    .where(eq(transactionsTable.userId, user.id))
    .orderBy(desc(transactionsTable.createdAt))
    .limit(limit);

  const result = txs.map((t) => ({
    id: t.id,
    type: t.type,
    description: t.description,
    amountCents: t.amountCents ?? null,
    txHash: t.txHash ?? null,
    onchainStatus: t.onchainStatus,
    createdAt: t.createdAt.toISOString(),
  }));

  res.json(ListActivityResponse.parse(result));
});

export default router;
