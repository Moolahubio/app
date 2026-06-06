import { Router, type IRouter } from "express";
import { requireAuth } from "../lib/auth";
import { networkName, explorerUrl, usdcContract } from "../lib/chain";

/**
 * Exposes the on-chain addresses the client needs to build user-signed
 * transactions. Plain JSON (not OpenAPI-generated) so it can ship without a
 * codegen pass; the frontend fetches it directly (see lib/onchain/config.ts).
 */
const router: IRouter = Router();

router.get("/onchain/config", requireAuth, (_req, res): void => {
  res.json({
    network: networkName(),
    explorerUrl: explorerUrl(),
    usdc: usdcContract(),
    goalVault: process.env.GOAL_VAULT_ADDRESS ?? null,
    circleFactory: process.env.CIRCLE_FACTORY_ADDRESS ?? null,
    accumulationFactory: process.env.ACCUMULATION_FACTORY_ADDRESS ?? null,
  });
});

export default router;
