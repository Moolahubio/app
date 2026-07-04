import { Router, type IRouter } from "express";
import {
  DepositFaucetBody,
  WithdrawFundsBody,
  ConfirmWithdrawalBody,
  GetWalletResponse,
  DepositFaucetResponse,
  WithdrawFundsResponse,
  ConfirmWithdrawalResponse,
  EnsureWalletGasResponse,
  SyncDepositsResponse,
} from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import { requireAllowedOrigin, requireJsonAndAllowedOrigin } from "../lib/origins";
import { sendError } from "../lib/errors";
import { getWalletForUser } from "../lib/wallet";
import { userOnchainBalanceSummary } from "../lib/onchainBalances";
import { faucetDeposit, syncDeposits, withdrawToAddress, confirmClientWithdrawal } from "../lib/deposits";
import { onchainEnabled, networkName, faucetEnabled, depositSyncEnabled, ensureGas, usdcContract } from "../lib/chain";
import { allowGasTopup } from "../lib/gasTopupThrottle";
import { verifyStepUp } from "../lib/stepUp";

const router: IRouter = Router();

router.get("/wallet", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  // No wallet is auto-created. Until the user explicitly sets one up (via the
  // "Continue with Privy" flow in the Wallet section), this returns an empty
  // state with hasWallet=false; the client renders the setup card.
  const wallet = await getWalletForUser(user.id);
  // Balances are sourced from on-chain (when configured) so what we display is
  // the REAL settled balance, not the ledger's optimistic view.
  const bal = await userOnchainBalanceSummary(user.id);

  res.json(
    GetWalletResponse.parse({
      availableCents: bal.availableCents,
      totalCents: bal.totalCents,
      goalAllocatedCents: bal.allocatedCents,
      pendingCents: bal.pendingCents,
      balanceUnavailable: bal.balanceUnavailable,
      address: wallet?.address ?? null,
      network: networkName(),
      onchainEnabled: onchainEnabled(),
      hasWallet: !!wallet,
      custody: wallet?.custody ?? null,
      usdcAddress: usdcContract(),
      faucetEnabled: faucetEnabled(),
      syncEnabled: depositSyncEnabled(),
    }),
  );
});

router.post("/wallet/deposit", requireJsonAndAllowedOrigin, requireAuth, async (req, res): Promise<void> => {
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

// Withdrawals send real funds to an address the caller supplies. A stolen
// session cookie (or a hijacked/scripted client) alone must never be enough
// to move funds off-platform — require fresh step-up proof of an existing
// login factor first, same as any other sensitive, fund-moving action.
router.post("/wallet/withdraw", requireJsonAndAllowedOrigin, requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = WithdrawFundsBody.safeParse(req.body);
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
    await withdrawToAddress(user.id, parsed.data.amountCents, parsed.data.destination);
  } catch (e) {
    sendError(res, e, "Withdrawal failed");
    return;
  }

  res.json(WithdrawFundsResponse.parse({ ok: true }));
});

// A non-custodial (Privy) wallet signs its OWN withdrawal on the user's device
// and broadcasts it; the server holds no key. This endpoint CONFIRMS that
// already-broadcast transfer by verifying the on-chain receipt, then records it
// for history. No step-up here — the user's own device key already authorized
// the move, and re-gating an irreversible, already-settled transfer could only
// strand it. (Server-custody wallets are refused inside confirmClientWithdrawal
// and use the step-up-gated /wallet/withdraw path instead.)
router.post("/wallet/withdraw/submitted", requireJsonAndAllowedOrigin, requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = ConfirmWithdrawalBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  try {
    await confirmClientWithdrawal(
      user.id,
      parsed.data.txHash,
      parsed.data.amountCents,
      parsed.data.destination,
    );
  } catch (e) {
    sendError(res, e, "Couldn't confirm withdrawal");
    return;
  }

  res.json(ConfirmWithdrawalResponse.parse({ ok: true }));
});

// Top up gas (MON) on a non-custodial wallet so its embedded EOA can pay for the
// user's own next signature. Only these wallets need it (server-custody wallets
// are gas-funded by the reconciler when it signs). No JSON body, so this uses
// requireAllowedOrigin like /wallet/sync. Per-user daily cap bounds gas-griefing.
router.post("/wallet/ensure-gas", requireAllowedOrigin, requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  if (!onchainEnabled()) {
    res.status(400).json({ error: "On-chain isn't enabled on this deployment." });
    return;
  }
  const wallet = await getWalletForUser(user.id);
  if (!wallet) {
    res.status(400).json({ error: "Set up your wallet first." });
    return;
  }
  if (wallet.custody !== "privy") {
    res.status(400).json({ error: "This wallet doesn't need a manual gas top-up." });
    return;
  }
  if (!allowGasTopup(user.id)) {
    res.status(429).json({ error: "Gas top-up limit reached for today. Please try again later." });
    return;
  }

  try {
    await ensureGas(wallet.address);
  } catch (e) {
    sendError(res, e, "Gas top-up failed");
    return;
  }

  res.json(EnsureWalletGasResponse.parse({ ok: true }));
});

router.post("/wallet/sync", requireAllowedOrigin, requireAuth, async (req, res): Promise<void> => {
  // Block sync on non-mainnet deployments where the configured token is
  // typically a mock-mintable asset (e.g. MockUSDC on Monad Testnet). Without
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
