import { useState } from "react";
import { Link, useLocation } from "wouter";
import {
  Bell,
  UserPlus,
  Users,
  ArrowDownLeft,
  ArrowUpRight,
  Target,
  PartyPopper,
  Sparkles,
} from "lucide-react";
import { cn, timeAgo } from "@/lib/utils";
import { useMarkAllNotificationsRead, getListNotificationsQueryKey } from "@workspace/api-client-react";
import { useQueryClient } from "@tanstack/react-query";

export type NotificationItem = {
  id: string;
  type: string;
  title: string;
  body: string;
  link: string | null;
  read: boolean;
  createdAt: string;
};

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

export function NotificationBell({
  notifications,
  unreadCount,
}: {
  notifications: NotificationItem[];
  unreadCount: number;
}) {
  const [open, setOpen] = useState(false);
  const markAllRead = useMarkAllNotificationsRead();
  const queryClient = useQueryClient();

  async function toggle() {
    const next = !open;
    setOpen(next);
    if (next && unreadCount > 0) {
      markAllRead.mutate(undefined, {
        onSuccess: () => queryClient.invalidateQueries({ queryKey: getListNotificationsQueryKey() })
      });
    }
  }

  return (
    <div className="relative">
      <button
        onClick={toggle}
        className="relative inline-flex h-10 w-10 cursor-pointer items-center justify-center rounded-xl border border-ink-900/10 bg-white text-ink-600 transition-[color,background-color,transform] duration-150 hover:border-ink-900/16 hover:text-ink-900 active:scale-95 focus-ring"
        aria-label="Notifications"
      >
        <Bell className="h-5 w-5" />
        {unreadCount > 0 && (
          <span className="absolute -right-1 -top-1 flex h-5 min-w-5 items-center justify-center rounded-full bg-jade-500 px-1 text-[10px] font-bold text-white ring-2 ring-mist">
            {unreadCount > 9 ? "9+" : unreadCount}
          </span>
        )}
      </button>

      {open && (
        <>
          <div
            className="fixed inset-0 z-[60] bg-ink-950/20 backdrop-blur-[2px]"
            aria-hidden
            onClick={() => setOpen(false)}
          />
          <div className="absolute right-0 z-[70] mt-2 w-[22rem] max-w-[calc(100vw-2rem)] overflow-hidden rounded-2xl border border-ink-900/10 bg-white">
            <div className="flex items-center justify-between border-b border-ink-900/[0.06] px-4 py-3">
              <p className="font-display text-sm font-bold text-ink-900">Notifications</p>
              <Link
                href="/notifications"
                onClick={() => setOpen(false)}
                className="text-xs font-medium text-jade-600 hover:text-jade-700"
              >
                View all
              </Link>
            </div>

            {notifications.length === 0 ? (
              <div className="px-4 py-10 text-center">
                <Bell className="mx-auto h-6 w-6 text-ink-300" />
                <p className="mt-2 text-sm text-ink-400">You&apos;re all caught up.</p>
              </div>
            ) : (
              <ul className="max-h-[26rem] divide-y divide-ink-900/[0.06] overflow-y-auto">
                {notifications.map((n) => {
                  const { icon: Icon, tone } = ICONS[n.type] ?? ICONS.system;
                  return (
                    <li key={n.id}>
                      <Link
                        href={n.link ?? "/activity"}
                        onClick={() => setOpen(false)}
                        className={cn(
                          "flex gap-3 px-4 py-3 transition-colors hover:bg-mist",
                          !n.read && "bg-jade-50/40",
                        )}
                      >
                        <span
                          className={cn(
                            "mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-2xl",
                            tone,
                          )}
                        >
                          <Icon className="h-4.5 w-4.5" />
                        </span>
                        <div className="min-w-0 flex-1">
                          <p className="text-sm font-semibold text-ink-900">{n.title}</p>
                          <p className="text-xs leading-snug text-ink-500">{n.body}</p>
                          <p className="mt-1 font-mono text-[10px] uppercase tracking-wide text-ink-400">
                            {timeAgo(n.createdAt)}
                          </p>
                        </div>
                        {!n.read && <span className="mt-1.5 h-2 w-2 shrink-0 rounded-full bg-jade-500" />}
                      </Link>
                    </li>
                  );
                })}
              </ul>
            )}
          </div>
        </>
      )}
    </div>
  );
}
