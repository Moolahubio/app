import { useEffect, useRef, useState } from "react";
import { Link } from "wouter";
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
  invite: { icon: UserPlus, tone: "bg-jade-50 text-jade-600 dark:bg-jade-500/15 dark:text-jade-300" },
  invite_accepted: { icon: Users, tone: "bg-jade-50 text-jade-600 dark:bg-jade-500/15 dark:text-jade-300" },
  circle_started: { icon: Users, tone: "bg-sky-50 text-sky-600 dark:bg-sky-500/15 dark:text-sky-300" },
  contribution: { icon: ArrowUpRight, tone: "bg-muted text-foreground" },
  payout: { icon: PartyPopper, tone: "bg-amber-50 text-amber-600 dark:bg-amber-500/15 dark:text-amber-300" },
  deposit: { icon: ArrowDownLeft, tone: "bg-jade-50 text-jade-600 dark:bg-jade-500/15 dark:text-jade-300" },
  withdrawal: { icon: ArrowUpRight, tone: "bg-muted text-foreground" },
  goal: { icon: Target, tone: "bg-jade-50 text-jade-600 dark:bg-jade-500/15 dark:text-jade-300" },
  yield: { icon: Sparkles, tone: "bg-jade-50 text-jade-600 dark:bg-jade-500/15 dark:text-jade-300" },
  system: { icon: Bell, tone: "bg-muted text-foreground" },
};

export function NotificationBell({
  notifications,
  unreadCount,
}: {
  notifications: NotificationItem[];
  unreadCount: number;
}) {
  const [open, setOpen] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const markAllRead = useMarkAllNotificationsRead();
  const queryClient = useQueryClient();

  useEffect(() => {
    if (!open) return;
    function onPointerDown(e: PointerEvent) {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    }
    function onKeyDown(e: KeyboardEvent) {
      if (e.key === "Escape") setOpen(false);
    }
    document.addEventListener("pointerdown", onPointerDown);
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [open]);

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
    <div className="relative" ref={containerRef}>
      <button
        onClick={toggle}
        className="relative inline-flex h-10 w-10 cursor-pointer items-center justify-center rounded-xl border border-border bg-card text-muted-foreground transition-[color,background-color,transform] duration-150 hover:bg-muted hover:text-foreground active:scale-95 focus-ring"
        aria-label="Notifications"
      >
        <Bell className="h-5 w-5" />
        {unreadCount > 0 && (
          <span className="absolute -right-1 -top-1 flex h-5 min-w-5 items-center justify-center rounded-full bg-jade-500 px-1 text-[10px] font-bold text-white ring-2 ring-background">
            {unreadCount > 9 ? "9+" : unreadCount}
          </span>
        )}
      </button>

      {open && (
        <div className="absolute right-0 z-[70] mt-2 w-[22rem] max-w-[calc(100vw-2rem)] overflow-hidden rounded-2xl border border-border bg-popover shadow-xl shadow-black/20">
            <div className="flex items-center justify-between border-b border-border px-4 py-3">
              <p className="font-display text-sm font-bold text-foreground">Notifications</p>
              <Link
                href="/notifications"
                onClick={() => setOpen(false)}
                className="text-xs font-medium text-jade-600 hover:text-jade-700 dark:text-jade-400 dark:hover:text-jade-300"
              >
                View all
              </Link>
            </div>

            {notifications.length === 0 ? (
              <div className="px-4 py-10 text-center">
                <Bell className="mx-auto h-6 w-6 text-muted-foreground" />
                <p className="mt-2 text-sm text-muted-foreground">You&apos;re all caught up.</p>
              </div>
            ) : (
              <ul className="max-h-[26rem] divide-y divide-border overflow-y-auto">
                {notifications.map((n) => {
                  const { icon: Icon, tone } = ICONS[n.type] ?? ICONS.system;
                  return (
                    <li key={n.id}>
                      <Link
                        href={n.link ?? "/transactions"}
                        onClick={() => setOpen(false)}
                        className={cn(
                          "flex gap-3 px-4 py-3 transition-colors hover:bg-accent",
                          !n.read && "bg-jade-50/40 dark:bg-jade-500/10",
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
                          <p className="text-sm font-semibold text-foreground">{n.title}</p>
                          <p className="text-xs leading-snug text-muted-foreground">{n.body}</p>
                          <p className="mt-1 font-mono text-[10px] uppercase tracking-wide text-muted-foreground">
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
      )}
    </div>
  );
}
