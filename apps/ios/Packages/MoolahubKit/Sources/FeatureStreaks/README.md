# FeatureStreaks: Savings streak

**Owner:** lane S (feature wave 1) · **Spec:** the wave-1 feature spec (private) §2 and its Streaks part ST.4 to ST.10 · `apps/ios/DESIGN.md` v2.2 (private)

## Keep (AppFeature calls these)
- `public struct StreakScreen: View`, `init(services:)`: pushed for `AppDestination.streak` (root `streak.screen`, inline title "Savings streak").
- `public struct StreakFrequencyScreen: View`, `init(services:)`: pushed for `AppDestination.streakFrequency` (root `streak.frequency.screen`, inline title "Streak frequency").
- `public struct NewBadgeSheet: View`, `init(services:badge:)`: presented by AppFeature's `AppRootView` only, for `AppSheet.newStreakBadge(_:)` (D-23).

## What is here (F0 stubs)
F0 created these as stubs with their bar titles and root identifiers only (SPEC §8.2 item 7, D-42): no figure and no placeholder copy. `NewBadgeSheet` has the title "New badge" and a primary "Done" (`streak.badgeSheet.done`) that calls `services.streaks.markBadgesSeen()` and dismisses. Lane S builds the screens, `TakeBreakSheet`, `ShareStreakSheet` and `StreakShareCard`.

## Rules that bite
- Every streak surface reads `services.streaks` (`StreakStore`, Auth): never a second store or a direct `GET /streaks`.
- Home's root and the Streak screen register as celebration hosts (`services.streaks.celebrationHosts`); only `AppRootView` presents the New badge sheet.
