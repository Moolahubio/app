import "server-only";
import { db } from "@/lib/db";
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
  const user = await db.user.findUnique({ where: { id: userId }, select: { email: true } });
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
    await db.notification.create({
      data: { userId, type: n.type, title: n.title, body: n.body, link: n.link },
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
    await db.notification.createMany({
      data: ids.map((userId) => ({
        userId,
        type: n.type,
        title: n.title,
        body: n.body,
        link: n.link,
      })),
    });
    if (opts?.email) await Promise.all(ids.map((id) => maybeEmail(id, n, opts)));
  } catch (e) {
    console.error("[notify] bulk failed:", e);
  }
}

export async function listNotifications(userId: string, limit = 20) {
  return db.notification.findMany({
    where: { userId },
    orderBy: { createdAt: "desc" },
    take: limit,
  });
}

export async function unreadCount(userId: string) {
  return db.notification.count({ where: { userId, read: false } });
}

export async function markAllRead(userId: string) {
  await db.notification.updateMany({ where: { userId, read: false }, data: { read: true } });
}

export async function markRead(userId: string, id: string) {
  await db.notification.updateMany({ where: { id, userId }, data: { read: true } });
}

export async function clearAll(userId: string) {
  await db.notification.deleteMany({ where: { userId } });
}
