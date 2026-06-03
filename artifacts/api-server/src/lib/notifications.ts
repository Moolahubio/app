import { eq, and, desc, count } from "drizzle-orm";
import { db, notificationsTable, usersTable } from "@workspace/db";
import { sendEmail, brandedEmail, appUrl } from "./email";

export type NotifyInput = {
  type: string;
  title: string;
  body: string;
  link?: string;
};

type NotifyOpts = { email?: boolean };

async function maybeEmail(userId: string, n: NotifyInput, opts?: NotifyOpts) {
  if (!opts?.email) return;
  const [user] = await db
    .select({ email: usersTable.email })
    .from(usersTable)
    .where(eq(usersTable.id, userId));
  if (!user?.email || user.email.endsWith("@privy.moolahub")) return;
  await sendEmail({
    to: user.email,
    subject: n.title,
    html: brandedEmail({
      heading: n.title,
      body: n.body,
      cta: n.link ? { label: "Open MoolaHub", href: appUrl(n.link) } : undefined,
    }),
    text: n.body,
  });
}

/** Create an in-app notification (and optionally email it). Never throws. */
export async function notify(userId: string, n: NotifyInput, opts?: NotifyOpts) {
  try {
    await db.insert(notificationsTable).values({
      userId,
      type: n.type,
      title: n.title,
      body: n.body,
      link: n.link ?? null,
    });
    await maybeEmail(userId, n, opts);
  } catch (e) {
    console.error("[notify] failed:", e);
  }
}

export async function notifyMany(userIds: string[], n: NotifyInput, opts?: NotifyOpts) {
  const ids = userIds.filter(Boolean);
  if (!ids.length) return;
  try {
    await db.insert(notificationsTable).values(
      ids.map((userId) => ({
        userId,
        type: n.type,
        title: n.title,
        body: n.body,
        link: n.link ?? null,
      })),
    );
    if (opts?.email) await Promise.all(ids.map((id) => maybeEmail(id, n, opts)));
  } catch (e) {
    console.error("[notify] bulk failed:", e);
  }
}

export async function listNotifications(userId: string, limit = 20) {
  return db
    .select()
    .from(notificationsTable)
    .where(eq(notificationsTable.userId, userId))
    .orderBy(desc(notificationsTable.createdAt))
    .limit(limit);
}

export async function unreadCount(userId: string): Promise<number> {
  const [r] = await db
    .select({ c: count() })
    .from(notificationsTable)
    .where(and(eq(notificationsTable.userId, userId), eq(notificationsTable.read, false)));
  return Number(r?.c ?? 0);
}

export async function markAllRead(userId: string) {
  await db
    .update(notificationsTable)
    .set({ read: true })
    .where(and(eq(notificationsTable.userId, userId), eq(notificationsTable.read, false)));
}

export async function markRead(userId: string, id: string) {
  await db
    .update(notificationsTable)
    .set({ read: true })
    .where(and(eq(notificationsTable.id, id), eq(notificationsTable.userId, userId)));
}

export async function clearAll(userId: string) {
  await db.delete(notificationsTable).where(eq(notificationsTable.userId, userId));
}
