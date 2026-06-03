import { Card } from "@/components/ui";
import { PageHeader } from "@/components/app/bits";
import { useListNotifications, useMarkNotificationRead, getListNotificationsQueryKey } from "@workspace/api-client-react";
import { useQueryClient } from "@tanstack/react-query";
import { Bell, UserPlus, Users, ArrowDownLeft, ArrowUpRight, Target, PartyPopper, Sparkles } from "lucide-react";
import { timeAgo, cn } from "@/lib/utils";
import { Link } from "wouter";

const ICONS: Record<string, { icon: typeof Bell; tone: string }> = {
  invite: { icon: UserPlus, tone: "bg-jade-50 text-jade-600" },
  invite_accepted: { icon: Users, tone: "bg-jade-50 text-jade-600" },
  circle_started: { icon: Users, tone: "bg-sky-50 text-sky-600" },
  contribution: { icon: ArrowUpRight, tone: "bg-ink-900/[0.06] text-ink-700" },
  payout: { icon: PartyPopper, tone: "bg-amber-50 text-amber-600" },
  deposit: { icon: ArrowDownLeft, tone: "bg-jade-50 text-jade-600" },
  withdrawal: { icon: ArrowUpRight, tone: "bg-ink-900/[0.06] text-ink-700" },
  goal: { icon: Target, tone: "bg-jade-50 text-jade-600" },
  yield: { icon: Sparkles, tone: "bg-jade-50 text-jade-600" },
  system: { icon: Bell, tone: "bg-ink-900/[0.06] text-ink-700" },
};

export default function NotificationsPage() {
  const { data, isLoading } = useListNotifications();
  const queryClient = useQueryClient();
  const markOneMutation = useMarkNotificationRead();

  if (isLoading) return <div className="p-8 text-center text-ink-400">Loading notifications...</div>;

  const notifications = data?.notifications ?? [];

  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <PageHeader
        eyebrow="Notifications"
        title="Everything that's happened"
        description="Invitations, contributions, payouts and more — your full MoolaHub activity."
      />

      <Card className="overflow-hidden p-0">
        {notifications.length === 0 ? (
          <div className="px-4 py-10 text-center">
            <Bell className="mx-auto h-6 w-6 text-ink-300" />
            <p className="mt-2 text-sm text-ink-400">You're all caught up.</p>
          </div>
        ) : (
          <ul className="divide-y divide-ink-900/[0.06]">
            {notifications.map((n) => {
              const { icon: Icon, tone } = ICONS[n.type] ?? ICONS.system;
              return (
                <li key={n.id}>
                  <Link
                    href={n.link ?? "/activity"}
                    onClick={() => {
                      if (!n.read) {
                        markOneMutation.mutate({ id: n.id }, {
                          onSuccess: () => queryClient.invalidateQueries({ queryKey: getListNotificationsQueryKey() })
                        });
                      }
                    }}
                    className={cn(
                      "flex gap-4 p-5 transition-colors hover:bg-mist",
                      !n.read && "bg-jade-50/40",
                    )}
                  >
                    <span
                      className={cn(
                        "mt-1 flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl",
                        tone,
                      )}
                    >
                      <Icon className="h-5 w-5" />
                    </span>
                    <div className="min-w-0 flex-1">
                      <p className="text-sm font-bold text-ink-900">{n.title}</p>
                      <p className="mt-1 text-sm leading-snug text-ink-600">{n.body}</p>
                      <p className="mt-2 font-mono text-[10px] uppercase tracking-wide text-ink-400">
                        {timeAgo(n.createdAt)}
                      </p>
                    </div>
                    {!n.read && <span className="mt-2 h-2.5 w-2.5 shrink-0 rounded-full bg-jade-500" />}
                  </Link>
                </li>
              );
            })}
          </ul>
        )}
      </Card>
    </div>
  );
}
