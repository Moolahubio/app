import { Router, type IRouter } from "express";
import { eq, and, desc } from "drizzle-orm";
import { db, notificationsTable, usersTable } from "@workspace/db";
import {
  MarkNotificationReadParams,
  ListNotificationsResponse,
  ClearNotificationsResponse,
  MarkAllNotificationsReadResponse,
  MarkNotificationReadResponse,
  GetNotificationPreferencesResponse,
  UpdateNotificationPreferencesBody,
  UpdateNotificationPreferencesResponse,
} from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import { categoriesForPreference } from "../lib/notifications";

const router: IRouter = Router();

const PREFERENCES = ["everything", "essential", "minimal", "custom"] as const;

function prefsPayload(preference: string, custom: Record<string, boolean> | null | undefined) {
  return { preference, categories: categoriesForPreference(preference, custom) };
}

router.get("/notifications/preferences", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  res.json(
    GetNotificationPreferencesResponse.parse(
      prefsPayload(user.notificationPreference ?? "everything", user.notificationPrefs),
    ),
  );
});

router.patch("/notifications/preferences", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = UpdateNotificationPreferencesBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  const preference = parsed.data.preference;
  if (!PREFERENCES.includes(preference as (typeof PREFERENCES)[number])) {
    res.status(400).json({ error: "Unknown notification preference." });
    return;
  }

  // Only persist the explicit per-category switches when in custom mode; the
  // preset tiers derive their categories deterministically at read time.
  const custom =
    preference === "custom"
      ? {
          money: parsed.data.categories?.money !== false,
          social: parsed.data.categories?.social !== false,
          engagement: parsed.data.categories?.engagement !== false,
        }
      : null;

  const [updated] = await db
    .update(usersTable)
    .set({ notificationPreference: preference, notificationPrefs: custom })
    .where(eq(usersTable.id, user.id))
    .returning();

  res.json(
    UpdateNotificationPreferencesResponse.parse(
      prefsPayload(updated.notificationPreference ?? "everything", updated.notificationPrefs),
    ),
  );
});

router.get("/notifications", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;

  const notifications = await db
    .select()
    .from(notificationsTable)
    .where(eq(notificationsTable.userId, user.id))
    .orderBy(desc(notificationsTable.createdAt))
    .limit(50);

  const unreadCount = notifications.filter((n) => !n.read).length;

  res.json(
    ListNotificationsResponse.parse({
      notifications: notifications.map((n) => ({
        id: n.id,
        type: n.type,
        title: n.title,
        body: n.body,
        link: n.link ?? null,
        read: n.read,
        createdAt: n.createdAt.toISOString(),
      })),
      unreadCount,
    })
  );
});

router.delete("/notifications", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  await db.delete(notificationsTable).where(eq(notificationsTable.userId, user.id));
  res.json(ClearNotificationsResponse.parse({ ok: true }));
});

router.post("/notifications/read-all", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  await db
    .update(notificationsTable)
    .set({ read: true })
    .where(eq(notificationsTable.userId, user.id));
  res.json(MarkAllNotificationsReadResponse.parse({ ok: true }));
});

router.post("/notifications/:id/read", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = MarkNotificationReadParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  await db
    .update(notificationsTable)
    .set({ read: true })
    .where(
      and(
        eq(notificationsTable.id, params.data.id),
        eq(notificationsTable.userId, user.id)
      )
    );

  res.json(MarkNotificationReadResponse.parse({ ok: true }));
});

export default router;
