import "server-only";
import { db } from "@/lib/db";

export type NotifyInput = {
  type: string;
  title: string;
  body: string;
  link?: string;
};

/** Create an in-app notification. Never throws into the calling flow. */
export async function notify(userId: string, n: NotifyInput) {
  try {
    await db.notification.create({
      data: { userId, type: n.type, title: n.title, body: n.body, link: n.link },
    });
  } catch (e) {
    console.error("[notify] failed:", e);
  }
}

export async function notifyMany(userIds: string[], n: NotifyInput) {
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
