import { Router, type IRouter } from "express";
import { and, eq, ne, sql } from "drizzle-orm";
import { db, usersTable, walletsTable } from "@workspace/db";
import { UpdateProfileBody, GetProfileResponse, UpdateProfileResponse } from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import { ObjectStorageService } from "../lib/objectStorage";
import { isUniqueViolation } from "../lib/dbErrors";

const router: IRouter = Router();

const USERNAME_RE = /^[a-zA-Z0-9_]{3,30}$/;

function profilePayload(u: typeof usersTable.$inferSelect, walletAddress: string | null) {
  return {
    id: u.id,
    name: u.name,
    email: u.email,
    username: u.username ?? null,
    dateOfBirth: u.dateOfBirth ?? null,
    nationality: u.nationality ?? null,
    avatarUrl: u.avatarUrl ?? null,
    walletAddress,
    createdAt: u.createdAt.toISOString(),
  };
}

router.get("/profile", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const [wallet] = await db.select().from(walletsTable).where(eq(walletsTable.userId, user.id));

  res.json(GetProfileResponse.parse(profilePayload(user, wallet?.address ?? null)));
});

router.patch("/profile", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = UpdateProfileBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  const updates: Partial<typeof usersTable.$inferInsert> = {};
  if (parsed.data.name != null) {
    const name = parsed.data.name.trim();
    if (!name) {
      res.status(400).json({ error: "Name can't be empty." });
      return;
    }
    updates.name = name;
  }
  if (parsed.data.avatarUrl !== undefined) {
    const a = parsed.data.avatarUrl;
    if (a !== null && a !== "") {
      // Only a real, allowlisted internal uploaded image is allowed — never an
      // arbitrary external URL (rendered in other users' browsers) nor a
      // disguised non-image upload.
      const objectStorage = new ObjectStorageService();
      const usable = await objectStorage.isUsableImageObject(a);
      if (!usable) {
        res.status(400).json({ error: "Invalid profile image." });
        return;
      }
      // Avatars are only ever displayed back to their owner, so lock the object
      // down to the owner. Until an object is bound here it has no ACL policy
      // and the serving route refuses to read it. Claiming fails if the object
      // is already owned by someone else, preventing object takeover by path.
      const claimed = await objectStorage.claimObjectEntityForOwner(
        a,
        user.id,
        "private",
      );
      if (!claimed) {
        res.status(400).json({ error: "Invalid profile image." });
        return;
      }
    }
    updates.avatarUrl = a || null;
  }
  if (parsed.data.dateOfBirth !== undefined) updates.dateOfBirth = parsed.data.dateOfBirth || null;
  if (parsed.data.nationality !== undefined) updates.nationality = parsed.data.nationality || null;

  if (parsed.data.username !== undefined) {
    const raw = parsed.data.username;
    if (raw === null || raw === "") {
      updates.username = null;
    } else {
      const username = raw.trim().toLowerCase();
      if (!USERNAME_RE.test(username)) {
        res.status(400).json({
          error: "Username must be 3–30 characters: letters, numbers, or underscores.",
        });
        return;
      }
      const [clash] = await db
        .select({ id: usersTable.id })
        .from(usersTable)
        .where(and(sql`lower(${usersTable.username}) = ${username}`, ne(usersTable.id, user.id)));
      if (clash) {
        res.status(409).json({ error: "That username is already taken." });
        return;
      }
      updates.username = username;
    }
  }

  let updated: typeof usersTable.$inferSelect;
  try {
    [updated] = await db
      .update(usersTable)
      .set(updates)
      .where(eq(usersTable.id, user.id))
      .returning();
  } catch (err) {
    // DB-level CI unique index is the source of truth; the pre-check above is
    // just UX. A concurrent rename that wins the race lands here as a unique
    // violation and maps to a clean 409 instead of a 500.
    if (isUniqueViolation(err)) {
      res.status(409).json({ error: "That username is already taken." });
      return;
    }
    throw err;
  }

  const [wallet] = await db.select().from(walletsTable).where(eq(walletsTable.userId, user.id));

  res.json(UpdateProfileResponse.parse(profilePayload(updated, wallet?.address ?? null)));
});

export default router;
