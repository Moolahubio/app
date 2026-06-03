import { Router, type IRouter } from "express";
import { GetSettlementOverviewResponse } from "@workspace/api-zod";
import { requireOperator } from "../lib/auth";
import { getSettlementOverview } from "../lib/settlement";
import { platformBalances } from "../lib/chain";

const router: IRouter = Router();

router.get("/operations/settlements", requireOperator, async (_req, res): Promise<void> => {
  const [overview, platform] = await Promise.all([getSettlementOverview(), platformBalances()]);

  res.json(
    GetSettlementOverviewResponse.parse({
      onchainEnabled: overview.onchainEnabled,
      maxAttempts: overview.maxAttempts,
      rowLimit: overview.rowLimit,
      truncated: overview.truncated,
      platform,
      groups: overview.groups,
    }),
  );
});

export default router;
