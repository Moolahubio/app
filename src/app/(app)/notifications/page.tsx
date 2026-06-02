import { Card } from "@/components/ui";
import { PageHeader } from "@/components/app/bits";
import { NotificationList } from "@/components/app/NotificationList";
import { requireUser } from "@/lib/server/auth";
import { listNotifications } from "@/lib/server/notifications";

export default async function NotificationsPage() {
  const user = await requireUser();
  const notifications = await listNotifications(user.id, 60);

  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <PageHeader
        eyebrow="Notifications"
        title="Everything that's happened"
        description="Invitations, contributions, payouts and more — your full MoolaHub activity."
      />

      <Card className="overflow-hidden p-0">
        <NotificationList
          items={notifications.map((n) => ({
            id: n.id,
            type: n.type,
            title: n.title,
            body: n.body,
            link: n.link,
            read: n.read,
            createdAt: n.createdAt.toISOString(),
          }))}
        />
      </Card>
    </div>
  );
}
