"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useTransition } from "react";
import {
  Bell,
  UserPlus,
  Users,
  ArrowDownLeft,
  ArrowUpRight,
  Target,
  PartyPopper,
  Sparkles,
  Check,
  Trash2,
} from "lucide-react";
import { cn, timeAgo } from "@/lib/utils";
import type { NotificationItem } from "@/components/app/NotificationBell";
import {
  markNotificationsReadAction,
  markOneNotificationReadAction,
  clearNotificationsAction,
} from "@/app/(app)/actions";

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

export function NotificationList({ items }: { items: NotificationItem[] }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const hasUnread = items.some((i) => !i.read);

  const run = (fn: () => Promise<void>) => start(async () => { await fn(); router.refresh(); });

  if (items.length === 0) {
    return (
      <div className="px-6 py-16 text-center">
        <Bell className="mx-auto h-7 w-7 text-ink-300" />
        <p className="mt-3 text-sm text-ink-400">No notifications yet.</p>
      </div>
    );
  }

  return (
    <div>
      <div className="flex items-center justify-end gap-2 border-b border-ink-900/[0.06] px-4 py-2.5">
        <button
          onClick={() => run(() => markNotificationsReadAction())}
          disabled={pending || !hasUnread}
          className="inline-flex items-center gap-1.5 rounded-full px-3 py-1.5 text-xs font-medium text-ink-600 transition-colors hover:bg-mist disabled:opacity-40 focus-ring"
        >
          <Check className="h-3.5 w-3.5" /> Mark all read
        </button>
        <button
          onClick={() => run(() => clearNotificationsAction())}
          disabled={pending}
          className="inline-flex items-center gap-1.5 rounded-full px-3 py-1.5 text-xs font-medium text-red-600 transition-colors hover:bg-red-50 disabled:opacity-40 focus-ring"
        >
          <Trash2 className="h-3.5 w-3.5" /> Clear all
        </button>
      </div>

      <ul className="divide-y divide-ink-900/[0.06]">
        {items.map((n) => {
          const { icon: Icon, tone } = ICONS[n.type] ?? ICONS.system;
          return (
            <li
              key={n.id}
              className={cn("flex items-start gap-3 px-5 py-4", !n.read && "bg-jade-50/40")}
            >
              <Link
                href={n.link ?? "/activity"}
                onClick={() => !n.read && run(() => markOneNotificationReadAction(n.id))}
                className="flex min-w-0 flex-1 items-start gap-4"
              >
                <span
                  className={cn(
                    "mt-0.5 flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl",
                    tone,
                  )}
                >
                  <Icon className="h-5 w-5" />
                </span>
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-semibold text-ink-900">{n.title}</p>
                  <p className="text-sm leading-snug text-ink-500">{n.body}</p>
                  <p className="mt-1 font-mono text-[10px] uppercase tracking-wide text-ink-400">
                    {timeAgo(n.createdAt)}
                  </p>
                </div>
              </Link>
              {!n.read && (
                <button
                  onClick={() => run(() => markOneNotificationReadAction(n.id))}
                  disabled={pending}
                  title="Mark as read"
                  className="mt-1 inline-flex h-7 w-7 items-center justify-center rounded-full text-ink-400 transition-colors hover:bg-jade-50 hover:text-jade-600 focus-ring"
                >
                  <Check className="h-4 w-4" />
                </button>
              )}
            </li>
          );
        })}
      </ul>
    </div>
  );
}
