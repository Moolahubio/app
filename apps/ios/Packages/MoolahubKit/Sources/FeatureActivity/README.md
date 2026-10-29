# FeatureActivity: Activity tab and the Activity receipt

**Owner:** Home/Activity engineer · **Simulator:** `MH-Home` · **Spec:** `apps/ios/DESIGN.md` v2 B2.6–B2.7 + J7 (and A8.19, Part W)

## Keep (AppFeature calls these)
- `public struct ActivityRootView: View`, `init(services:)`: Activity tab root (large title "Activity").
- `public struct ActivityReceiptSheet: View`, `init(item:services:)`: the Activity receipt (B2.7), presented by AppFeature for `AppSheet.activityReceipt(item)`; Activity and Home rows open it with `services.navigator.present(.activityReceipt(item))`.

## What is built (v2)
- **Activity** (B2.6): `API.Activity.list(limit: 100)` through `RemoteResource` (cache key `.activity`); refreshes on pull and when an app sheet closes.
- Days as list headers (`subheadlineEmphasis` `textSecondary`, `.isHeader`, `activity.section.<dayKey>`): "Today", "Yesterday", else `.dateTime.weekday(.wide).day().month(.abbreviated)` (+ `.year()` outside this year). Under each, `ActivityRow(item)` (symbol slot at x 16, text at x 52, the time as sub-line, `activity.row.<id>`), no container, no dividers; days 12 pt apart.
- Status block: `ErrorBanner` with "Try again" when a refresh failed, the "Updated …" line for the cached snapshot and for rows a failed refresh kept (D5). Footer "Showing your latest 100 moves." (`activity.footer`) when exactly 100 came back.
- Empty: `EmptyState` "No activity yet" / "Money you add, move and pay in shows up here." (no button). Never loaded: `ErrorState` "We couldn't load your activity" with "Try again". Loading: `ActivitySkeleton`, one element "Loading activity…".
- **Activity receipt** (B2.7, J7): `ReceiptStep` with the item's description as title, the signed amount (`activity.receipt.amount`), rows Type, Date, Status; notes "This can take a few minutes." / "Nothing was taken."; on a Processing item one `GET /activity?limit=100` read, matched by `id`, never a guess. Sheet root `activity.receipt`.
- Status comes only from `onchainStatus` (`MoveStatus`), never guessed. `txHash` is never shown.
