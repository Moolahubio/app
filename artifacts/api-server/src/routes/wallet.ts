import { Router, type IRouter } from "express";
import {
  DepositFaucetBody,
  WithdrawFundsBody,
  GetWalletResponse,
  DepositFaucetResponse,
  WithdrawFundsResponse,
  SyncDepositsResponse,
  GetOnrampUrlResponse,
} from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import { createWalletForUser } from "../lib/wallet";
import { userBalances } from "../lib/ledger";
import { faucetDeposit, syncDeposits, withdrawToAddress } from "../lib/deposits";
import { onchainEnabled, networkName } from "../lib/chain";
import { onrampEnabled, createOnrampSessionToken, buildOnrampUrl } from "../lib/onramp";

const router: IRouter = Router();

router.get("/wallet", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const wallet = await createWalletForUser(user.id);
  const bal = await userBalances(user.id);

  res.json(
    GetWalletResponse.parse({
      availableCents: bal.availableCents,
      totalCents: bal.totalCents,
      goalAllocatedCents: bal.allocatedCents,
      address: wallet.address,
      network: networkName(),
      onrampEnabled: onrampEnabled(),
      onchainEnabled: onchainEnabled(),
    }),
  );
});

router.post("/wallet/deposit", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = DepositFaucetBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: parsed.error.message });
    return;
  }

  try {
    await faucetDeposit(user.id, parsed.data.amountCents);
  } catch (e) {
    res.status(400).json({ error: e instanceof Error ? e.message : "Deposit failed" });
    return;
  }

  res.json(DepositFaucetResponse.parse({ ok: true }));
});

router.post("/wallet/withdraw", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = WithdrawFundsBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: parsed.error.message });
    return;
  }

  try {
    await withdrawToAddress(user.id, parsed.data.amountCents, parsed.data.destination);
  } catch (e) {
    res.status(400).json({ error: e instanceof Error ? e.message : "Withdrawal failed" });
    return;
  }

  res.json(WithdrawFundsResponse.parse({ ok: true }));
});

router.post("/wallet/sync", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const result = await syncDeposits(user.id);
  res.json(
    SyncDepositsResponse.parse({
      ok: true,
      credited: result.credited,
      totalCents: result.totalCents,
    }),
  );
});

router.get("/wallet/onramp-url", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  if (!onrampEnabled()) {
    res.status(400).json({ error: "Card purchases are not configured." });
    return;
  }

  const wallet = await createWalletForUser(user.id);
  const forwarded = req.headers["x-forwarded-for"];
  const clientIp =
    (Array.isArray(forwarded) ? forwarded[0] : forwarded?.split(",")[0]?.trim()) ??
    req.socket.remoteAddress ??
    "0.0.0.0";

  try {
    const sessionToken = await createOnrampSessionToken(wallet.address, clientIp);
    const url = buildOnrampUrl(sessionToken);
    res.json(GetOnrampUrlResponse.parse({ url }));
  } catch (e) {
    res.status(400).json({ error: e instanceof Error ? e.message : "Could not start purchase" });
  }
});

export default router;
