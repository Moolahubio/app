import { Router, type IRouter } from "express";
import { eq } from "drizzle-orm";
import { db, usersTable, walletsTable } from "@workspace/db";
import { UpdateProfileBody, GetProfileResponse, UpdateProfileResponse } from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";

const router: IRouter = Router();

router.get("/profile", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const [wallet] = await db.select().from(walletsTable).where(eq(walletsTable.userId, user.id));

  res.json(
    GetProfileResponse.parse({
      id: user.id,
      name: user.name,
      email: user.email,
      avatarUrl: user.avatarUrl ?? null,
      walletAddress: wallet?.address ?? null,
      createdAt: user.createdAt.toISOString(),
    })
  );
});

router.patch("/profile", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = UpdateProfileBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  const updates: Partial<typeof usersTable.$inferInsert> = {};
  if (parsed.data.name != null) updates.name = parsed.data.name;
  if (parsed.data.avatarUrl !== undefined) updates.avatarUrl = parsed.data.avatarUrl;

  const [updated] = await db
    .update(usersTable)
    .set(updates)
    .where(eq(usersTable.id, user.id))
    .returning();

  const [wallet] = await db.select().from(walletsTable).where(eq(walletsTable.userId, user.id));

  res.json(
    UpdateProfileResponse.parse({
      id: updated.id,
      name: updated.name,
      email: updated.email,
      avatarUrl: updated.avatarUrl ?? null,
      walletAddress: wallet?.address ?? null,
      createdAt: updated.createdAt.toISOString(),
    })
  );
});

export default router;
