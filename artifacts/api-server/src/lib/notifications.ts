import { eq, and, desc, count, inArray } from "drizzle-orm";
import { db, notificationsTable, usersTable } from "@workspace/db";
import { sendEmail, brandedEmail, appUrl } from "./email";

export type NotifyInput = {
  type: string;
  title: string;
  body: string;
  link?: string;
};

type NotifyOpts = { email?: boolean };

/**
 * Notification categories drive the per-user preference tiers. Money movements are
 * the most important (kept even at "minimal"); social activity is added at
 * "essential"; engagement nudges (streak reminders) only at "everything"/custom.
 */
export type NotificationCategory = "money" | "social" | "engagement";

const CATEGORY_BY_TYPE: Record<string, NotificationCategory> = {
  deposit: "money",
  withdrawal: "money",
  payout: "money",
  refund: "money",
  contribution: "money",
  fee: "money",
  goal_allocate: "money",
  goal_release: "money",
  accumulation: "money",
  invite: "social",
  invite_accepted: "social",
  circle_started: "social",
  rotation: "social",
  circle: "social",
  goal: "social",
  streak_reminder: "engagement",
};

export function categoryForType(type: string): NotificationCategory {
  return CATEGORY_BY_TYPE[type] ?? "social";
}

export const DEFAULT_CATEGORIES: Record<NotificationCategory, boolean> = {
  money: true,
  social: true,
  engagement: true,
};

/** Resolve the effective per-category switches for a preference tier. */
export function categoriesForPreference(
  preference: string | null | undefined,
  custom: Record<string, boolean> | null | undefined,
): Record<NotificationCategory, boolean> {
  switch (preference) {
    case "minimal":
      return { money: true, social: false, engagement: false };
    case "essential":
      return { money: true, social: true, engagement: false };
    case "custom":
      return {
        money: custom?.money !== false,
        social: custom?.social !== false,
        engagement: custom?.engagement !== false,
      };
    case "everything":
    default:
      return { money: true, social: true, engagement: true };
  }
}

function passesPreference(
  type: string,
  preference: string | null | undefined,
  custom: Record<string, boolean> | null | undefined,
): boolean {
  return categoriesForPreference(preference, custom)[categoryForType(type)];
}

async function maybeEmail(email: string | null | undefined, n: NotifyInput, opts?: NotifyOpts) {
  if (!opts?.email) return;
  if (!email || email.endsWith("@privy.moolahub")) return;
  await sendEmail({
    to: email,
    subject: n.title,
    html: brandedEmail({
      heading: n.title,
      body: n.body,
      cta: n.link ? { label: "Open MoolaHub", href: appUrl(n.link) } : undefined,
    }),
    text: n.body,
  });
}

/**
 * Create an in-app notification (and optionally email it), respecting the user's
 * notification preference. Never throws.
 */
export async function notify(userId: string, n: NotifyInput, opts?: NotifyOpts) {
  try {
    const [user] = await db
      .select({
        email: usersTable.email,
        preference: usersTable.notificationPreference,
        prefs: usersTable.notificationPrefs,
      })
      .from(usersTable)
      .where(eq(usersTable.id, userId));
    if (!user) return;
    if (!passesPreference(n.type, user.preference, user.prefs)) return;

    await db.insert(notificationsTable).values({
      userId,
      type: n.type,
      title: n.title,
      body: n.body,
      link: n.link ?? null,
    });
    await maybeEmail(user.email, n, opts);
  } catch (e) {
    console.error("[notify] failed:", e);
  }
}

export async function notifyMany(userIds: string[], n: NotifyInput, opts?: NotifyOpts) {
  const ids = userIds.filter(Boolean);
  if (!ids.length) return;
  try {
    const users = await db
      .select({
        id: usersTable.id,
        email: usersTable.email,
        preference: usersTable.notificationPreference,
        prefs: usersTable.notificationPrefs,
      })
      .from(usersTable)
      .where(inArray(usersTable.id, ids));

    const recipients = users.filter((u) => passesPreference(n.type, u.preference, u.prefs));
    if (!recipients.length) return;

    await db.insert(notificationsTable).values(
      recipients.map((u) => ({
        userId: u.id,
        type: n.type,
        title: n.title,
        body: n.body,
        link: n.link ?? null,
      })),
    );
    if (opts?.email) await Promise.all(recipients.map((u) => maybeEmail(u.email, n, opts)));
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
