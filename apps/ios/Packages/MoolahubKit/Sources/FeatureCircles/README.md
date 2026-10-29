# FeatureCircles: groups

**Owner:** Groups engineer · **Simulator:** `MH-Circles` · **Spec:** `apps/ios/DESIGN.md` v2 B4 (B4.0 to B4.27) + J5 (and Part A, Part W)

The API says "circles"; the UI says "group", always.

## Keep (AppFeature calls these)
- `public struct GroupsRootView: View`, `init(services:)`: Groups tab root (large title "Groups").
- `public struct GroupDetailView: View`, `init(services:groupID:)`: pushed for `AppDestination.groupDetail(id:)`.
- `public struct CreateGroupSheet: View`, `init(services:)`: `AppSheet.createGroup`.

## Build (v2)
1. **Groups list** B4.1 to B4.9 (`GroupsListView.swift`): `API.Groups.list()` + `API.Groups.invites()`; "Invitations ({n})" with `InviteCard`s (Join and Decline dialogs attached to the card), "Your groups" with `GroupCard`s (outlined cards, `PressableCardButtonStyle(restingFill: Palette.canvas)`, ordered Active, Forming, Completed), the "How groups work" `SettingsRow` and its info sheet. Loading: the header plus two outlined group-card skeletons. Empty: `EmptyState`. Never loaded: `ErrorState`. Refresh or invitations failed: `ErrorBanner`s in the status block, then the freshness line.
2. **Create group** B4.10 to B4.12 (`CreateGroupView.swift`): `ChoiceCard`s for the kind, inline `AmountEntry`, a system `Stepper` with its value as a figure, segmented frequency, the invite field with "Add" and `RemovableChip`s in the public `ChipFlowLayout`, the summary; "Create group" pinned (`PinnedActionBar`) with its reserved `DisabledReasonLine`; "Discard this?" on Close after any edit, swipe-down blocked then. Body via `CircleInput.takeTurns(...)` / `.saveTogether(...)`.
3. **Group detail** B4.13 to B4.23 (`GroupDetailScreen.swift`): `IdentityBandScreen` + `IdentityBand(tint: Palette.headerBand)` holding the status block, `AvatarStack`, the status line and the payout figure; facts as `DetailRowView`s; the one action (Pay in, the "Paid in this round" pill, Start group, or a line); Build your group (forming) with `SettingsValueRow` invited rows; `RoundTimeline` or `SaveTogetherProgress`; `MemberRow`s; pay-ins as `ActivityRow(symbol: nil, labelStyle: .titleFirst)`; `TechnicalDetailsRow` behind the setting. More menu (`ellipsis`) and the Delete dialog.
4. **Invite sheet** B4.24 (`InviteSheet.swift`) and **Pay in** J5, B4.25, B4.26 (`PayInSheet.swift`): `ReviewStep` (no keypad), Face ID, `API.Groups.contribute(groupID:)` once, `ReceiptStep` whose status and Date come only from matching `GET /activity`. Short of money: disabled confirm, the red reason line and "Add test money", which presents `services.navigator.sheetView(for: .addTestMoney)` on top.

## Rules that bite
- Never show `potCents` as what anyone receives.
- Some server errors say "circle": show them verbatim (FQ26).
- Pay-in is a money move: never retried; `.noResponse` → the ErrorBanner "We couldn't confirm this move. Check Activity before you try again." with "View activity".
- No containers on Group detail, Create group, Invite or Pay in: only group cards, invite cards and choice cards are outlined cards (A3.7, A8.5).
- Full-width rows (`MemberRow`, `RoundTimeline`, `ActivityRow`, `SettingsRow`, `SettingsValueRow`) pad themselves to the gutter: keep them outside the gutter-padded stacks.
