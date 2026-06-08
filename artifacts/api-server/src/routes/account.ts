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
import { DeactivateAccountResponse, DeleteAccountBody, DeleteAccountResponse } from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import { requireAllowedOrigin } from "../lib/origins";
import { userBalances } from "../lib/ledger";

const router: IRouter = Router();
const COOKIE = "moolahub_session";

// Deactivation is reversible: we record the timestamp and end all sessions. The
// next successful login clears `deactivatedAt` and restores access.
router.post("/account/deactivate", requireAllowedOrigin, requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;

  await db.update(usersTable).set({ deactivatedAt: new Date() }).where(eq(usersTable.id, user.id));
  await db.delete(sessionsTable).where(eq(sessionsTable.userId, user.id));

  res.clearCookie(COOKIE);
  res.json(DeactivateAccountResponse.parse({ ok: true }));
});

// Deletion is guarded: an account holding funds or with live circle commitments
// can't be deleted. When clear, we anonymize PII, revoke credentials, and end
// every session. Ledger/circle/goal history is retained for integrity but no
// longer tied to identifiable data.
router.delete("/account", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = DeleteAccountBody.safeParse(req.body);
  if (!parsed.success || parsed.data.confirm !== "DELETE") {
    res.status(400).json({ error: 'Type "DELETE" to confirm.' });
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
