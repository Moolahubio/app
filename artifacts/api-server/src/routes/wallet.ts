import { Router, type IRouter } from "express";
import {
  DepositFaucetBody,
  WithdrawFundsBody,
  GetWalletResponse,
  DepositFaucetResponse,
  WithdrawFundsResponse,
  SyncDepositsResponse,
} from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import { sendError } from "../lib/errors";
import { createWalletForUser } from "../lib/wallet";
import { userBalances } from "../lib/ledger";
import { faucetDeposit, syncDeposits, withdrawToAddress } from "../lib/deposits";
import { onchainEnabled, networkName, faucetEnabled } from "../lib/chain";

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
      onchainEnabled: onchainEnabled(),
    }),
  );
});

router.post("/wallet/deposit", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  // The faucet mints test balance with no real funding source. Refuse it
  // outright on mainnet / when disabled so it can't be used to conjure
  // spendable funds in production.
  if (!faucetEnabled()) {
    res.status(403).json({ error: "The test faucet is not available." });
    return;
  }
  const parsed = DepositFaucetBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  try {
    await faucetDeposit(user.id, parsed.data.amountCents);
  } catch (e) {
    sendError(res, e, "Deposit failed");
    return;
  }

  res.json(DepositFaucetResponse.parse({ ok: true }));
});

router.post("/wallet/withdraw", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = WithdrawFundsBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  try {
    await withdrawToAddress(user.id, parsed.data.amountCents, parsed.data.destination);
  } catch (e) {
    sendError(res, e, "Withdrawal failed");
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

export default router;
