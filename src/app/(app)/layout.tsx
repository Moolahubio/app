import { requireUser } from "@/lib/server/auth";
import { userBalances } from "@/lib/server/ledger";
import { getReminders } from "@/lib/server/reminders";
import { listNotifications, unreadCount } from "@/lib/server/notifications";
import { AppShell } from "@/components/app/AppShell";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const user = await requireUser();
  const [{ totalCents }, reminders, notifications, unread] = await Promise.all([
    userBalances(user.id),
    getReminders(user.id),
    listNotifications(user.id, 15),
    unreadCount(user.id),
  ]);
  const next = reminders[0];

  return (
    <AppShell
      user={{ name: user.name, kycStatus: user.kycStatus }}
      balanceCents={totalCents}
      reminder={
        next
          ? { title: next.title, amountCents: next.amountCents, dueDate: next.dueDate.toISOString() }
          : null
      }
      notifications={notifications.map((n) => ({
        id: n.id,
        type: n.type,
        title: n.title,
        body: n.body,
        link: n.link,
        read: n.read,
        createdAt: n.createdAt.toISOString(),
      }))}
      unreadCount={unread}
    >
      {children}
    </AppShell>
  );
}
