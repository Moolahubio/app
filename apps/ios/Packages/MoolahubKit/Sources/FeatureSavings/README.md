# FeatureSavings: goals

**Owner:** Savings engineer · **Simulator:** `MH-Savings` · **Spec:** `apps/ios/DESIGN.md` v2 B3 + J2–J4 (and A8, Part W)

## Keep (AppFeature calls these)
- `public struct SavingsRootView: View`, `init(services:)`: Savings tab root (large title "Savings").
- `public struct GoalDetailView: View`, `init(services:goalID:)`: pushed for `AppDestination.goalDetail(id:)` from any tab.
- `public struct MoveToGoalSheet: View`, `init(services:goalID:)`: `AppSheet.moveToGoal(goalID:)`; nil starts at "Choose a goal".
- `public struct CreateGoalSheet: View`, `init(services:)`: `AppSheet.createGoal`.

## Build (v2)
1. **Savings list** B3.2–B3.7 (`SavingsListScreen.swift`): the status block (ErrorBanner, "Updated {N} min ago"), the "In goals" total as a page fact (`savings.summary`), `SectionHeader("Your goals")`, a 2-column `Grid` of `GoalCard` tiles (`PressableCardButtonStyle(restingFill: Palette.surface)`, one column at AX sizes), the explanation; `LoadingPlaceholder` with DesignSystem `SkeletonCard` tiles (`fillPressed` blocks on `surface`, each line reserved at its real height by `SkeletonTextLine`), `EmptyState`, `ErrorState`; toast "Goal deleted." (DesignSystem `.toast`, drawn in its own window above the navigation bar).
2. **Create goal** B3.8–B3.10 (`CreateGoalFlow.swift`): `MoolaTextField`, `EmojiPickerCell` grid of `GoalIcon.allCases` (sends the emoji exactly, `color: "jade"`), `PickerField` "Target amount" → the amount step (`AmountStepView`), system graphical `DatePicker` with no container or jade tint, segmented frequency, plan sentence; `PinnedActionBar` with the ErrorBanner, "Create goal" and the reserved `DisabledReasonLine`.
3. **Goal detail** B3.11–B3.16 (`GoalDetailScreen.swift`): `IdentityBandScreen` + `IdentityBand` in `GoalTint.color(forAPIKey:)`, `GoalDetailHeader` (`GoalCard(.detail)`, one element `savings.detail.header`), the two actions and "Nothing to move yet.", the fee note, `GoalPlanSection` (`DetailRowView` rows), `SavedEachMonthChart`, `GoalHistorySection` (`ActivityRow`, `MoolaDates.dateAndTime`), technical details (`TechnicalDetailsRow`); `GoalDetailSkeleton` on a `fill` band, the 404 and never-loaded `ErrorState`s on `canvas`. Toast "Goal created.".
4. **Move to goal** J2, B3.17–B3.21 (`MoveToGoalFlow.swift`): `ChooseGoalStep` (`GoalCard(.row)` in `RowButtonStyle`, hint "Chooses this goal."), the amount step (max = `GET /wallet` available, never assumed; "Next step" chip `isSuggested`), `ReviewStep` with Face ID (`.goal` To row), `TrackedReceiptView`.
5. **Move to balance** J3, B3.22–B3.25 (`MoveToBalanceFlow.swift`): amount → review with the fee preview → `StepUpStepView` → receipt from the server's `grossCents/feeCents/netCents`.
6. **Delete goal** J4, B3.26–B3.28 (`DeleteGoalFlow.swift`): name subtitle, consequence (`savings.delete.body`), `StepUpFields` inline, tonal destructive "Delete goal"; receipt only when money moved, else the toast on Savings.

Shared here (`SavingsSupport.swift`, `MoneyMoveSteps.swift`): `SavingsSheetClose` (DesignSystem `SheetCloseButton(identifier: "savings.sheet.close")` with "Discard this?" attached to it), `savingsSheetChrome` (`SheetChrome([.large])` + swipe blocking), `SheetStepTitle` (`title1`), `MoveFailure` (J0.7), `ReceiptStatusTracker` (J0.6), `StepUpState` (J0.4), `SavingsEvents` (refetch + one pending toast; `goalsChanged()` also posts Domain's `AppSignals.moneyMoved` so Home refreshes, J0.1, J0.7), `savingsRead` (every Savings `GET` goes through it).

## Debug-only test hooks (`#if DEBUG`, `SavingsDebugReads`; the toast hold is DesignSystem's)
- `-mh-savings-slow-reads`: every Savings read waits 20 s (skeletons B3.3, B3.13, B3.18, the balance loading line B3.19).
- `-mh-savings-offline-reads`: every Savings read fails as "not connected" before it leaves (B3.5, B3.6, B3.15, B3.18, B3.19 errors).
- Reads only; money moves never go through these. Used by `SavingsFlowUITests.testNotFoundErrorAndLoadingStates`.
- `-mh-hold-toasts` (`ToastWindow.holdLaunchArgument`, DesignSystem; it holds every toast): "Goal created." and "Goal deleted." stay on screen after their 3 s (a newer toast still replaces them), so a UI test on a busy Mac can shoot them and check their place (B3.7, B3.12). Used by `SavingsFlowUITests.testCreateFormDiscardDialogAndToastPlacement`.

## Rules that bite
- Pace and plan maths are in Domain (`GoalPace`, `ContributionPlan`, ports of the web). Don't re-implement them.
- Deadlines are UTC midnight: display with `APIDate.formatUTCDay`; history and receipt dates with `MoolaDates.dateAndTime`.
- A 401 on release/delete is a wrong password: inline, never sign-out (the client already distinguishes it).
- Money moves are never retried; an uncertain outcome disables the confirm and offers "View activity".
- Sheets paint no background on iOS 26 (`SheetChrome` paints `sheetCanvas` only on iOS 17/18); never `.moolaCanvas()` inside a sheet.
- Toasts wait for the screen they confirm: "Goal deleted." shows only after the Savings list has refetched for the delete (the goal is already gone from it, B3.7); "Goal created." shows 0.3 s after the goal loads, once the skeleton has cross-faded into it (B3.12).
- Presenting Add test money from inside your sheet: `services.navigator.sheetView(for: .addTestMoney)` in your own `.sheet`.

## Open against DESIGN.md (shared components, asked of the integrator)
- None open: the loading context line (B3.19) is `AmountEntry(contextLoadingLabel:)` and "of {target}" sits 4 pt under the saved figure in `GoalCard(.detail)` (B3.11).
