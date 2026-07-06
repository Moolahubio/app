import { Router, type IRouter } from "express";
import { GetReferralOverviewResponse, WithdrawReferralEarningsBody } from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import { requireJsonAndAllowedOrigin } from "../lib/origins";
import { sendError } from "../lib/errors";
import { verifyStepUp } from "../lib/stepUp";
import { getReferralOverview, withdrawReferralEarnings } from "../lib/referrals";

const router: IRouter = Router();

router.get("/referral", requireAuth, async (req, res): Promise<void> => {
  try {
    const user = (req as AuthRequest).user;
    const overview = await getReferralOverview(user.id);
    res.json(GetReferralOverviewResponse.parse(overview));
  } catch (e) {
    sendError(res, e, "Failed to load your referral dashboard");
  }
});

router.post(
  "/referral/withdraw",
  requireJsonAndAllowedOrigin,
  requireAuth,
  async (req, res): Promise<void> => {
    const user = (req as AuthRequest).user;
    const parsed = WithdrawReferralEarningsBody.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: "Invalid request" });
      return;
    }

    // High-risk money movement: require fresh proof of every configured factor.
    const stepUp = await verifyStepUp(user, parsed.data);
    if (!stepUp.ok) {
      res.status(stepUp.status).json({ error: stepUp.error });
      return;
    }

    try {
      await withdrawReferralEarnings(user.id, parsed.data.amountCents);
    } catch (e) {
      sendError(res, e, "Withdrawal failed");
      return;
    }

    res.json({ ok: true });
  },
);

export default router;
