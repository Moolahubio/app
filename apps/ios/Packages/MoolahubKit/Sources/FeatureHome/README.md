# FeatureHome: Home tab, Add test money, Cash out

**Owner:** Home engineer · **Simulator:** `MH-Home` · **Spec:** `apps/ios/DESIGN.md` v2 B2.0–B2.5 + J0, J1, J6 (and A8, Part W)

## Keep (AppFeature calls these)
- `public struct HomeRootView: View`, `init(services: AppServices)`: Home tab root, inside the Home `NavigationStack`. No navigation bar (the greeting band instead).
- `public struct AddTestMoneySheet: View`, `init(services: AppServices)`: presented for `AppSheet.addTestMoney` (from Home and from the Groups Pay-in flow).
- `public struct CashOutSheet: View`, `init()`: presented for `AppSheet.cashOut`.

## What is built (v2)
1. **Home** (B2.1) from `GET /dashboard/summary` (`RemoteResource`, cache key `.dashboard`) and the signed-in user's first name.
   - `GreetingHeader("Good to see you, {first}", detail: updatedText, identifier: "home.greeting")` in `GreetingHeaderChrome` (the band fills the status bar; pull to refresh opens band colour).
   - `BalanceCard(state:actions:)`: the total as type, the two action tiles ("Add money", "Move to goal") and the "Cash out" / "History" links. States `.loading`, `.loaded`, `.loadFailed` (never loaded: the screen's only "Try again").
   - `DisclosureFooter()`, then "Your goals" 52 pt below its text (`GoalCard(layout: .row)` with the 52 pt `EmojiTile`, dividers from x 80), "Your groups" (`GroupCard`, only when there are groups), "Recent activity" (`ActivityRow(symbol: nil)`, the D7 day sub-line, each row opens `AppSheet.activityReceipt`). "See all" only when its section has items (D8).
   - States: C2 skeleton (`HomeSectionsSkeleton`), C3 one failed block, C4 kept figures + `ErrorBanner` + "Updated …" in the band (shown for the cached snapshot and whenever a refresh failed with figures on screen), C5 pending and stale lines, and while the summary says `balanceUnavailable` every goal row says "May be out of date" (B2.0.2 fallback until the server sends the per-goal flag), C6 no goals, C7 no groups, C8 no activity.
2. **Add test money** (B2.3, B2.4, J1): `SheetChrome([.large])`, `SheetCloseButton(identifier: "home.addMoney.close")`, `title1` title, amber `NoticeBanner` "Test money", `AmountEntry` ($0.01 to $1,000.00, presets $50 · $100 · $250 · $500), pinned "Add test money" (`home.addMoney.submit`, loading "Adding…"). One `POST /wallet/deposit`, never retried; failures in an `ErrorBanner` above the button (refusal title "Didn't go through. Nothing was taken."; an unknown outcome says "View activity", which closes the sheet and opens Activity, and blocks a second attempt). When a banner appears the content scrolls to its end, so the keypad's last row clears the taller bar; at accessibility sizes the banner moves into the content and the sheet scrolls to it (J0.10). Then `ReceiptStep` ("Test money added", To "Balance", Date in `MoolaDates.dateAndTime`), whose status comes only from matching `GET /activity?limit=10` (`MoneyMoveReceipt`).
3. **Cash out** (B2.5, J6): the info sheet (`SheetChrome([.medium])`), one sentence, pinned "Done".

## Rules that bite
- Money moves are never retried. `.noResponse` (and an unreadable answer) → "We couldn't confirm this move. Check Activity before you try again." with "View activity".
- Never `$0.00` for data that didn't load: skeleton first, then one error block.
- Invisible crypto: no "USDC", "wallet", "transaction" outside `DisclosureFooter` (DesignSystem).
