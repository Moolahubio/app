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
import { getWalletForUser } from "../lib/wallet";
import { userBalances } from "../lib/ledger";
import { faucetDeposit, syncDeposits, withdrawToAddress } from "../lib/deposits";
import { onchainEnabled, networkName, faucetEnabled, depositSyncEnabled } from "../lib/chain";

const router: IRouter = Router();

router.get("/wallet", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  // No wallet is auto-created. Until the user explicitly sets one up (via the
  // "Continue with Privy" flow in the Wallet section), this returns an empty
  // state with hasWallet=false; the client renders the setup card.
  const wallet = await getWalletForUser(user.id);
  const bal = await userBalances(user.id);

  res.json(
    GetWalletResponse.parse({
      availableCents: bal.availableCents,
      totalCents: bal.totalCents,
      goalAllocatedCents: bal.allocatedCents,
      address: wallet?.address ?? null,
      network: networkName(),
      onchainEnabled: onchainEnabled(),
      hasWallet: !!wallet,
      faucetEnabled: faucetEnabled(),
      syncEnabled: depositSyncEnabled(),
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
  // Block sync on non-mainnet deployments where the configured token is
  // typically a mock-mintable asset (e.g. MockUSDC on Base Sepolia). Without
  // this guard any authenticated user can mint tokens to their wallet via the
  // permissionless MockUSDC.mint() function and then call sync to import those
  // fabricated tokens as real spendable balance. Operators may explicitly opt
  // in on a testnet with a genuine non-mintable token via ENABLE_DEPOSIT_SYNC.
  if (!depositSyncEnabled()) {
    res.status(403).json({ error: "Deposit sync is not available on this network." });
    return;
  }
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
