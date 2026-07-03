import { Router, type IRouter } from "express";
import { and, eq, inArray } from "drizzle-orm";
import {
  db,
  usersTable,
  sessionsTable,
  passkeysTable,
  circlesTable,
  circleMembersTable,
  goalsTable,
} from "@workspace/db";
import { DeactivateAccountBody, DeactivateAccountResponse, DeleteAccountBody, DeleteAccountResponse } from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import { requireJsonAndAllowedOrigin } from "../lib/origins";
import { userBalances } from "../lib/ledger";
import { verifyStepUp } from "../lib/stepUp";

const router: IRouter = Router();
const COOKIE = "moolahub_session";

// Deactivation is destructive enough (immediately signs the account out
// everywhere) that a stolen session alone must not be sufficient — require
// step-up proof of an existing factor (password, 2FA code, or emailed reauth
// code) first, same as any other sensitive account-lifecycle action.
router.post("/account/deactivate", requireJsonAndAllowedOrigin, requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = DeactivateAccountBody.safeParse(req.body ?? {});
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  const stepUp = await verifyStepUp(user, parsed.data);
  if (!stepUp.ok) {
    res.status(stepUp.status).json({ error: stepUp.error });
    return;
  }

  await db.update(usersTable).set({ deactivatedAt: new Date() }).where(eq(usersTable.id, user.id));
  await db.delete(sessionsTable).where(eq(sessionsTable.userId, user.id));

  res.clearCookie(COOKIE);
  res.json(DeactivateAccountResponse.parse({ ok: true }));
});

// Deletion is guarded: an account holding funds or with live circle commitments
// can't be deleted. When clear, we anonymize PII, revoke credentials, and end
// every session. Ledger/circle/goal history is retained for integrity but no
// longer tied to identifiable data. Permanently destroying the account is
// irreversible, so — beyond typing "DELETE" — the caller must also prove an
// existing login factor via step-up; a stolen session alone is not enough.
router.delete("/account", requireJsonAndAllowedOrigin, requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = DeleteAccountBody.safeParse(req.body);
  if (!parsed.success || parsed.data.confirm !== "DELETE") {
    res.status(400).json({ error: 'Type "DELETE" to confirm.' });
    return;
  }

  const stepUp = await verifyStepUp(user, parsed.data);
  if (!stepUp.ok) {
    res.status(stepUp.status).json({ error: stepUp.error });
    return;
  }

  const balances = await userBalances(user.id);
  if (balances.totalCents > 0) {
    res.status(409).json({
      error: "Withdraw your funds and release any goals before deleting your account.",
    });
    return;
  }

  const activeCircles = await db
    .select({ id: circlesTable.id })
    .from(circleMembersTable)
    .innerJoin(circlesTable, eq(circleMembersTable.circleId, circlesTable.id))
    .where(
      and(
        eq(circleMembersTable.userId, user.id),
        inArray(circlesTable.status, ["forming", "active"]),
      ),
    );
  if (activeCircles.length) {
    res.status(409).json({
      error: "Leave or complete your active circles before deleting your account.",
    });
    return;
  }

  const activeGoals = await db
    .select({ id: goalsTable.id })
    .from(goalsTable)
    .where(and(eq(goalsTable.userId, user.id), eq(goalsTable.status, "active")));
  if (activeGoals.length) {
    res.status(409).json({
      error: "Release your active goals before deleting your account.",
    });
    return;
  }

  await db
    .update(usersTable)
    .set({
      name: "Deleted member",
      email: `deleted+${user.id}@deleted.moolahub`,
      passwordHash: null,
      privyDid: null,
      username: null,
      avatarUrl: null,
      dateOfBirth: null,
      nationality: null,
      twoFactorEnabled: false,
      twoFactorSecret: null,
      twoFactorBackupCodes: null,
      deletedAt: new Date(),
    })
    .where(eq(usersTable.id, user.id));

  await db.delete(passkeysTable).where(eq(passkeysTable.userId, user.id));
  await db.delete(sessionsTable).where(eq(sessionsTable.userId, user.id));

  res.clearCookie(COOKIE);
  res.json(DeleteAccountResponse.parse({ ok: true }));
});

export default router;
