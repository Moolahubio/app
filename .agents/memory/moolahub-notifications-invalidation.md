---
name: Notifications require client-side query invalidation
description: Why backend-created notifications sometimes don't show in the bell, and what mutations must invalidate.
---

# The bell won't update unless the mutation invalidates the notifications query

The notification bell (`app-layout.tsx` → `NotificationBell`) reads
`useListNotifications()` (key: `getListNotificationsQueryKey()`). The backend creates
notifications for most activities via `notify()`/`notifyMany()` (it is non-throwing by
design), including **goal deletion** (unconditional in `deleteGoal`).

**Trap:** the AppLayout stays mounted across in-app navigation, so the notifications query
does not refetch on its own after a mutation. If a mutation's `onSuccess` invalidates
goals/wallet/dashboard but **not** `getListNotificationsQueryKey()`, the new notification
exists in the DB but the bell shows stale data until a window refocus or full remount.

**Symptom seen:** deleting a goal created the notification server-side, but it never appeared
in the bell because the delete `onSuccess` didn't invalidate the notifications key.

**How to apply:** any client mutation that triggers a backend notification (goal
allocate/release/delete, contributions, etc.) should also
`queryClient.invalidateQueries({ queryKey: getListNotificationsQueryKey() })` in its success
path so the bell + unread badge refresh immediately.
