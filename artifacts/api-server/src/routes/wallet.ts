import { Router, type IRouter } from "express";
import { eq } from "drizzle-orm";
import { db, walletsTable, transactionsTable } from "@workspace/db";
import {
  DepositFaucetBody,
  WithdrawFundsBody,
  GetWalletResponse,
  DepositFaucetResponse,
  WithdrawFundsResponse,
  SyncDepositsResponse,
  GetOnrampUrlResponse,
} from "@workspace/api-zod";
import { requireAuth, getOrCreateWallet, type AuthRequest } from "../lib/auth";

const router: IRouter = Router();

router.get("/wallet", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const wallet = await getOrCreateWallet(user.id);

  res.json(
    GetWalletResponse.parse({
      availableCents: wallet.availableCents,
      totalCents: wallet.availableCents + wallet.goalAllocatedCents,
      goalAllocatedCents: wallet.goalAllocatedCents,
      address: wallet.address,
      network: wallet.network,
      onrampEnabled: wallet.onrampEnabled,
      onchainEnabled: wallet.onchainEnabled,
    })
  );
});

router.post("/wallet/deposit", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = DepositFaucetBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: parsed.error.message });
    return;
  }

  const wallet = await getOrCreateWallet(user.id);
  await db
    .update(walletsTable)
    .set({ availableCents: wallet.availableCents + parsed.data.amountCents })
    .where(eq(walletsTable.id, wallet.id));

  await db.insert(transactionsTable).values({
    userId: user.id,
    type: "deposit",
    description: "Testnet faucet deposit",
    amountCents: parsed.data.amountCents,
    onchainStatus: "confirmed",
  });

  res.json(DepositFaucetResponse.parse({ ok: true }));
});

router.post("/wallet/withdraw", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = WithdrawFundsBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: parsed.error.message });
    return;
  }

  const wallet = await getOrCreateWallet(user.id);
  if (wallet.availableCents < parsed.data.amountCents) {
    res.status(400).json({ error: "Insufficient balance" });
    return;
  }

  await db
    .update(walletsTable)
    .set({ availableCents: wallet.availableCents - parsed.data.amountCents })
    .where(eq(walletsTable.id, wallet.id));

  await db.insert(transactionsTable).values({
    userId: user.id,
    type: "withdrawal",
    description: `Withdrawal to ${parsed.data.destination.slice(0, 10)}...`,
    amountCents: parsed.data.amountCents,
    onchainStatus: "pending",
  });

  res.json(WithdrawFundsResponse.parse({ ok: true }));
});

router.post("/wallet/sync", requireAuth, async (req, res): Promise<void> => {
  res.json(SyncDepositsResponse.parse({ ok: true, credited: 0, totalCents: 0 }));
});

router.get("/wallet/onramp-url", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const wallet = await getOrCreateWallet(user.id);
  const url = `https://pay.coinbase.com/buy/select-asset?appId=${process.env.NEXT_PUBLIC_CDP_PROJECT_ID ?? "demo"}&destinationWallets=${encodeURIComponent(JSON.stringify([{ address: wallet.address, assets: ["USDC"], blockchains: ["base"] }]))}`;
  res.json(GetOnrampUrlResponse.parse({ url }));
});

export default router;
