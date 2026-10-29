# MoolaHub iOS

Native SwiftUI app (iPhone, iOS 17.0+, built with Xcode 26 / iOS 26 SDK, Swift 6 language mode with complete strict concurrency). This dev build talks only to the local backend: test money, no blockchain.

- Design source of truth: `DESIGN.md`, which is kept private and is not in this repository (it is gitignored here); code comments that cite `DESIGN.md §…` refer to it. Architecture decisions: [`docs/ios-app-plan.md`](../../docs/ios-app-plan.md).
- Project: `project.yml` (XcodeGen) → `Moolahub.xcodeproj` (generated, committed, never hand-edited).
- All code lives in the local package `Packages/MoolahubKit`. The `Moolahub` app target only owns the bundle: `Config/Info*.plist` and the asset catalog (no bundled fonts: SF Pro and SF Pro Rounded are the system's).

## 1. Run the backend

From the repo root:

```sh
scripts/dev-ios-backend.sh          # add --reset to rebuild the demo data
```

It starts local Postgres if needed, migrates and seeds `moolahub_ios_dev`, and serves the API on `0.0.0.0:8787`. It prints both URLs:

- Simulator: `http://localhost:8787/api`
- iPhone on the same Wi-Fi: `http://<this Mac>.local:8787/api`

It also writes `apps/ios/Config/Local.xcconfig` (gitignored) with this Mac's local network name (`DEV_MAC_HOST`), which the iPhone build uses as its default server. Rebuild the app after it changes. The file belongs to the checkout the script runs from: if you build the app from another checkout or worktree, run the script there once or copy the file over. A hand-edited file (more than the one `DEV_MAC_HOST` line) is left alone.

Demo login: `demo@moolahub.test` (friends: `kofi@`, `esi@`, `yaw@`, `abena@moolahub.test`). The password is the `DEMO_PASSWORD` constant in `artifacts/api-server/scripts/seed-ios-dev.ts`. New sign-ups get their email code in the server log (`[DEV ONLY] verification code …`).

## 2. Run on the Simulator

```sh
cd apps/ios
xcodegen generate                      # after any project.yml change or new top-level file in the app target
open Moolahub.xcodeproj                 # scheme "Moolahub", destination iPhone 17 Pro, Run
```

Command line (what the architect verified):

```sh
xcodebuild -project apps/ios/Moolahub.xcodeproj -scheme Moolahub \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath <your-derived-data> build
xcrun simctl install 'iPhone 17 Pro' <your-derived-data>/Build/Products/Debug-iphonesimulator/Moolahub.app
xcrun simctl launch 'iPhone 17 Pro' io.moolahub.app.dev            # add -mh-reset-state for a clean start
```

`-mh-reset-state` (Debug only) deletes the stored session token, cached snapshots and device settings before launch.

## 3. Run on an iPhone

1. iPhone and Mac on the same Wi-Fi; iPhone in Developer Mode (Settings → Privacy & Security → Developer Mode) and connected once by cable so Xcode registers it.
2. In Xcode pick the iPhone as the destination and Run. Signing is automatic with team `96X7N58MVV` (bundle id `io.moolahub.app.dev`). First launch: trust the developer certificate in Settings → General → VPN & Device Management.
3. Allow "Local Network" when iOS asks (needed to reach the Mac).
4. The Welcome screen shows `Server: <this Mac>.local:8787` (`your-mac.local:8787` if `Config/Local.xcconfig` is missing: run the backend script once, or copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig` and set `DEV_MAC_HOST` to the output of `scutil --get LocalHostName` followed by `.local`, then rebuild). Tap **Change** to open Developer settings: test the connection, pick a preset or type the Mac's IP (`http://192.168.x.x:8787/api`), Save.

Command-line device build (proves signing): `xcodebuild -project apps/ios/Moolahub.xcodeproj -scheme Moolahub -destination 'generic/platform=iOS' -derivedDataPath …/dd-<you> -allowProvisioningUpdates build`.

## 4. Module map

```
Moolahub (app target: Info.plist, assets (AccentColor, LaunchBackground, LaunchMark), @main)
└── AppFeature        root view, session gate (cross-fade), TabView, Router, app lock UI, privacy cover, developer settings + design specimen (Debug)
    ├── FeatureAuth   FeatureHome   FeatureSavings   FeatureCircles   FeatureActivity   FeatureAccount
    │     (each depends on the five shared modules below, never on each other or on AppFeature)
    ├── Auth          SessionStore, AppLock, DeviceAuthenticator, DeviceSettings, AppServices, Navigator, RemoteResource
    ├── APIClient     APIClient actor, Endpoint / APIRequest, API catalog, APIError, ServerEnvironment
    ├── Persistence   KeychainTokenStore, SnapshotCache
    ├── DesignSystem  v2 tokens (Palette, TypeToken, Spacing/Radius/Size/Motion), chrome, MoolaMark, Wordmark, all DESIGN.md Part A components
    └── Domain        Money, AmountEntryBuffer, ContributionPlan, GoalPace, GoalIcon, vocabularies, Validation, DTOs, AppTab/AppDestination/AppSheet
```

| Module | What's in it |
|---|---|
| Domain | `AppSignals.moneyMoved` (features tell Home to refresh without importing each other), `Money` (Int64 cents; `formatted(_:direction:)` fixed to en_US; `parse(_:)` = the web's `parseAmountToCents`), `AmountEntryBuffer` (keypad rules), `FeeRate`, `GoalProgress`, `ContributionPlan` + `GoalPace` (ports of `contribution-plan.ts`), `GoalIcon` (the 12 curated goal emoji sent on create; its SF Symbol mapping is no longer used for display), `ActivityKind` (W9.4 symbols), `MoveStatus`, `GroupKind/Status/Frequency`, `Validation` (server rules), `APIDate`/`APICoding`, `Secret`/`SessionToken` (never print), Codable DTOs for every route the app uses, `AppTab` (A7.2 symbols) / `AppDestination` / `AppSheet` (incl. `.activityReceipt(ActivityItem)`). |
| APIClient | `APIClient` actor (headers, `{}` bodies, no cookies, 401 → expiry handler, no retries, no logging), `Endpoint` protocol + `APIRequest<Response>`, the `API.*` catalog, `APIError` with DESIGN.md v2 W6 copy, `ServerEnvironment` (Debug URLs, Release placeholder that refuses to run). |
| Persistence | `KeychainTokenStore` (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), `SnapshotCache` actor (Application Support, per user, cleared on sign-out, excluded from backup) + `SnapshotAge` ("Updated 5 min ago"). |
| Auth | `SessionStore` (only place the token is stored/sent/deleted; `refreshUser()` returns its non-401 error), `AppLock` (launch + after 60s in background), `DeviceAuthenticator` (`.deviceOwnerAuthentication`, `BiometryKind`), `DeviceSettings`, `AppServices` (the dependency container), `Navigator`, `RemoteResource` (cache-then-network screen state). |
| DesignSystem | DESIGN.md v2 Part A. **Tokens**: `Palette`/`PaletteUIColor` (light, dark, dark elevated for sheets, Increase Contrast; `UIColor.moolaToken`), `GoalTint`, `TypeToken` + `.textStyle(_:)` (SF Pro / SF Pro Rounded tabular, `@ScaledMetric(relativeTo:)`, caps outside the size owner), `@ScaledTypeFont`, `Spacing`, `Radius`, `Size`, `Motion`, `NavigationBarFonts`. **Containers and press**: `.tileStyle(fill:)`, `.outlinedCardStyle(fill:)`, `PressableCardButtonStyle(restingFill:)`, `RowButtonStyle`, `.moolaCanvas()`. **Chrome**: `SheetChrome`/`.sheetChrome(_:)`, `SheetCloseButton(identifier:)`, `TabBarNeverMinimizes`, `HardTopScrollEdge`, `IdentityBand`/`IdentityBandScreen`/`BelowIdentityBand`, `GreetingHeader`/`GreetingHeaderChrome`, `PinnedActionBar`/`PinnedBarMetrics`/`DisabledReasonLine`. **Components**: `BalanceCard`, `QuickActionButton` (action tile), `MoneyText`, `GoalCard` (row/tile/detail), `EmojiTile`/`EmojiIdentity`/`EmojiPickerCell`, `ProgressBar`, `StatusPill`, `PaceText`, `GroupCard`, `InviteCard`, `AvatarView`, `AvatarStack`, `MemberRow`, `RoundTimeline`, `SaveTogetherProgress`, `ChoiceCard`, `MoolaButton`/`MoolaButtonStyle`/`MoolaButtonLabelStyle`, `TextLinkButton`, `SectionHeader`/`SectionLinkStyle`, `AmountEntry`/`AmountPreset`/`ChipFlowLayout`/`RemovableChip`, `ReviewStep`, `ReceiptStep`/`ReceiptSymbol`, `DetailRow`/`DetailRowView`, `StepUpFields`, `ActivityRow`, `EmptyState`, `ErrorState`, `SkeletonBlock`/`SkeletonBar`/`SkeletonCard`/`LoadingPlaceholder`, `DisclosureFooter`/`AboutBalanceSheet`/`Disclosure`, `ErrorBanner`, `NoticeBanner`, `.toast(_:)` (drawn by `ToastWindow`, a window of its own above the navigation bar and sheets), `TechnicalDetailsRow`, `MoolaTextField`, `PickerField`, `ReadOnlyField`, `CodeField`, the settings rows (`SettingsRow`, `SettingsRowLabel`, `SettingsValueRow`, `SettingsToggleRow`, `SettingsSelectableRow`, `SettingsGroupDivider`, `SettingsGroupFootnote`, `SettingsGroupLabel`), `MoolaDates`. The v1 APIs U5 removes (`cardStyle`, `moolaShadow`, `eyebrowStyle`, `GoalIconWell`, `StatusPill(pace:)`/`(groupStatus:)`, `Palette.surfaceRaised`/`progressFill`, …) are gone. Every component has a `#Preview`; Developer settings → Design specimen shows them all on a simulator. |
| AppFeature | `AppComposition.live()`, `AppRootView` (root swaps cross-fade), `MainTabView` (system `TabView`, jade selected tab, ink inside each tab's `NavigationStack`, never minimizes, re-tap pops to root), `Router` (implements `Navigator`; presents `.activityReceipt`), `DeepLink` (stub, nothing registered), lock screen, app-lock offer, privacy cover, restore-failed and not-configured screens, Debug-only `DeveloperSettingsView` and `DesignSpecimenView`. |

## 5. Conventions for feature engineers

**Where files go.** Only inside your own `Packages/MoolahubKit/Sources/Feature<Name>/` folder. Shared modules, `Package.swift`, `project.yml` and the app target belong to the architect/integration engineer. If you need something shared, build it inside your feature and say so in your report. No third-party dependencies.

**Public entry points.** Keep the names and initializers listed in your folder's `README.md`; AppFeature calls them. Everything else can be `internal`.

**Dependencies.** Your entry view receives `services: AppServices` (also available as `@Environment(AppServices.self)`). It holds `api`, `session`, `cache`, `settings`, `appLock`, `authenticator`, `buildInfo`, `navigator`.

**Calling the API.**
```swift
let goals = try await services.api.send(API.Goals.list())
```
`send` throws `APIError` (typed). In a plain `do/catch` the error is `any Error`; use `do throws(APIError) { … } catch { error.message(for: .screen) }` or `catch let error as APIError`. A route missing from the catalog is declared locally:
```swift
extension API.Notifications {
    static func clear() -> APIRequest<OkResponse> { .delete("/notifications") }
}
```
Paths start with `/`; ids go through `.pathSegment`. Mutations automatically send `Content-Type: application/json` and `{}` when there is no body. Public (signed-out) routes pass `authentication: .none`.

**Screen state.** Use `RemoteResource` for anything a screen loads: `load()` in `.task`, `refresh()` in `.refreshable`; render `phase` (`.loading` → skeleton, `.failed` → `ErrorState`, `.loaded` → content plus `ErrorBanner` if `error != nil`, plus `updatedText()` when showing cached data). Never show `$0.00` for data you don't have.

**Money.** Amounts are `Money` (Int64 cents). Display with `MoneyText` or `money.formatted(...)`; parse with `AmountEntryBuffer`/`Money.parse`. Never `Double`. Money moves (`addTestMoney`, `allocate`, `release`, goal `delete`, `contribute`) are single attempts: never retry, show `error.message(for: .moneyMove)`; on `.noResponse` send the user to Activity. Receipts decide Done/Processing only by matching `GET /activity` (DESIGN.md v2 J0.6).

**Auth errors.** Only a 401 `{"error":"Unauthorized"}` on an authenticated route signs the user out, and the client handles it for you (you get `.sessionExpired`; show nothing, the root swaps to Sign in). A 401 on step-up, password or 2FA endpoints is `.rejected(401, message)`: show it inline.

**Navigation.**
- Inside your tab: `NavigationLink(value: YourRoute.x)` + `.navigationDestination(for: YourRoute.self)` registered in your root view.
- Another feature's screen: `NavigationLink(value: AppDestination.goalDetail(id: id))` or `services.navigator.open(.goalDetail(id:))` (registered by AppFeature on every tab).
- Tabs: `services.navigator.select(.activity)`. App sheets: `services.navigator.present(.moveToGoal(goalID: nil))`. Inside your own sheet, nest another with `services.navigator.sheetView(for:)`.

**Face ID confirm.** `await services.authenticator.authenticate(reason: DeviceAuthenticator.Reason.confirmMoneyMove)`; button title and symbol from `services.authenticator.biometryKind().confirmTitle` / `.symbolName`. `.cancelled` → "Cancelled. Nothing was taken."

**Look and copy (DESIGN.md v2).** The spec is `DESIGN.md` v2 (Part A tokens and components, Part B your screens, Part J money moves, Part W copy, Part U migration). Rules that are easy to get wrong:
- **Tokens only**: `Palette.*`, `.textStyle(.headline)`, `Spacing.*`, `Radius.*`, `Size.*`, `Motion.*`; no raw hex, no `.opacity()` on a token, no `Color.primary`/`.secondary`, no `Font.custom`, no `.font(.system(size:))` for text (use `.textStyle` or `@ScaledTypeFont`). A-R's `Size.button`/`smallButton`/`field` ship as `Size.buttonHeight`/`smallButtonHeight`/`textFieldHeight`, and `Motion.reduced` as `Motion.reducedCrossfade`.
- **Type**: SF Pro for words, SF Pro Rounded with tabular digits for standalone figures (`displayHero`, `displayAmount`, `amountCard`, `amountRow`, `amountSmall`, `keypad`, `code`). Regular, Medium, Bold only; no tracking (except `code`); never step a weight for Bold Text. An amount inside a sentence stays in the sentence's style with `.monospacedDigit()`. Coloured words inside a line use `Text` interpolation, never `Text + Text`. No bundled fonts.
- **Layout**: screen gutter `Spacing.screenGutter` (**16**), sheet inset `Spacing.sheetPadding` (**20**), `sectionGap` 52, `headingToContent` 16, `gridGap` 12; one left edge at the gutter plus at most one media text column (x 80 for 52 pt emoji tiles and avatars, x 52 for 24 pt symbol slots). Containers only for tappable or decision objects (`.tileStyle`, `.outlinedCardStyle`); facts, settings, receipts and the balance sit on the page with no box. No shadows in content.
- **Glass**: Liquid Glass only from system chrome (`TabView`, navigation and toolbar items, sheets, dialogs). Never `.glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)` or any `Material` in content. Every sheet uses `SheetChrome` (no `presentationBackground` of your own, no `.moolaCanvas()` inside an iOS 26 sheet); Close is `SheetCloseButton(identifier:)` in `.cancellationAction` (first step) or `.topBarTrailing` (pushed step), never `.confirmationAction`. Pinned bottom buttons use `PinnedActionBar`.
- **Emoji**: a goal's own API `emoji` on an `EmojiTile` (tint from the API `color` via `GoalTint`) is the only place an emoji may appear. Never in labels, buttons, money copy, navigation, headings, empty states, toasts; `CopyCheckTests` scans every string literal for them.
- **Colour**: one ink primary (`ctaBackground`); links are ink; jade only for money in, progress, "Your turn", "Goal reached", identity tiles and bands and the selected tab; amber and red only for states that need attention. Normal states ("On track", "Processing…", "Active", "Paid in") are `textSecondary` words.
- **Copy**: verbatim from DESIGN.md (W10 is the index), sentence case, real `…`, straight `'`, no emoji, no "!". No "USDC", wallet, address, transaction, blockchain, gas, Privy or chain words outside the disclosure footer and its sheet, About and legal, Technical details and Developer settings.
- **Shared pieces added by the integration pass**: `.toast($message)` floats above the navigation bar in its own window (no feature-local toast windows); `AppSignals.postMoneyMoved()` (Domain) after any money move or uncertain outcome; `TextLinkButton(_:systemImage:alignment:action:)` (`.trailing`/`.leading` when the link sits at an edge, so a wrapped label follows it); `ChipFlowLayout(spacing:alignment:)` (`.leading` under a leading-aligned field); `AmountEntry(…, contextLoadingLabel:)` (skeleton context line while its figure loads); `CodeField(identifier:)` is optional.
- **Shared pieces added by the fix pass (round 1)**: the lock screen and the privacy cover are drawn by AppFeature's `SecurityOverlayWindow` (a window above every sheet and toast; it also tells `AppLock` when the scene leaves and returns), so never draw either inside your screen; `APIClient.walletForMoneyMove()` for a money move's maximum (a `balanceUnavailable` answer is a failed read, never $0.00, J0.8); a 5xx without the API's JSON envelope on a mutation is `.noResponse` (an unknown outcome, J0.7); `AppSignals.postViewActivityRequested()` (Domain) when "View activity" closes a sheet, so a sheet under it closes too; skeletons from DesignSystem (`SkeletonTextLine(token, leading:/leadingWidth:/trailing:/trailingWidth:, color:)` with heights from `TypeToken.capHeight`, `GoalRowSkeleton(inset:)`, `ActivityRowSkeleton(showsSymbol:)`, `SkeletonCard` = the B3.3 tile) inside one `LoadingPlaceholder`, which pulses only the blocks (labels, headings and grounds stay at full opacity); `String.lineEndMiddleDot` / `keepingMiddleDotsAtLineEnds` for every drawn " · "; `Motion.animation(_:reduceMotion:)` for every reduce-motion pair; `Size.hairline`, `focusBorder`, `focusBorderIncreasedContrast`, `selectionRing`, `goalRowBottomPadding`; `Palette.systemDestructive` on a destructive item in a system `Menu`; `PinnedBarMetrics.amountStepHardEdge`; `AuthScreen(…, nextField:, layoutKey:)` keeps the focused field and the next one above the pinned bar.
- **No v1 APIs**: the U5 removals are deleted from DesignSystem, with no forwarders left. If a v1 name does not compile, use its v2 replacement in DESIGN.md U2 to U5; never re-add it.

**Accessibility.** Money already reads as "1,240.50 US dollars". Cards are one element with a hint. Don't put `\n` inside a single `Text` (use two `Text` views): the accessibility audit reports it as clipped text. Inside a `Button` label, draw one text at a time: a second `Text` kept at `.opacity(0)` (even with `.accessibilityHidden(true)`) is exposed to UI tests and the audit as a static text of its own on iOS 26.5, so label queries and the contrast audit find it; reserve space with `.hidden()` copies instead (as `MoolaButton` does). Check Dynamic Type at AX sizes (A2.5 rule 8 layout switches), light, dark, Increase Contrast and Reduce Motion in previews and on the simulator.

**Previews.** Use `RemoteResource.preview(value)` and real-shaped values in `#Preview`s. Never ship sample data in a live code path.

## 6. Build and test your scheme

Each package library has its own scheme. Always pass your own derived data path and your own simulator, so five people can build at once:

```sh
# from the repo root
xcodebuild -project apps/ios/Moolahub.xcodeproj -scheme FeatureSavings \
  -destination 'platform=iOS Simulator,name=MH-Savings' \
  -derivedDataPath <your-derived-data> build

# The whole app on your simulator:
xcodebuild -project apps/ios/Moolahub.xcodeproj -scheme Moolahub \
  -destination 'platform=iOS Simulator,name=MH-Savings' \
  -derivedDataPath <your-derived-data> build
```

Simulators: `MH-Auth`, `MH-Home`, `MH-Savings`, `MH-Circles`, `MH-Account` (one per engineer); `iPhone 17 Pro` is for integration/QA.

Tests (all run on a simulator):

```sh
# Everything: package tests (Domain, APIClient, Persistence), app-hosted tests, UI smoke + accessibility audit
xcodebuild -project apps/ios/Moolahub.xcodeproj -scheme Moolahub \
  -destination 'platform=iOS Simulator,name=<your sim>' -derivedDataPath …/dd-<you> test

# Package tests only
cd apps/ios/Packages/MoolahubKit && xcodebuild test -scheme MoolahubKit-Package \
  -destination 'platform=iOS Simulator,name=<your sim>' -derivedDataPath …/dd-<you>-pkg

# UI tests against the live dev backend (reads the demo password from the seed file)
MH_BACKEND_LOG=<backend log> apps/ios/scripts/ui-test.sh '<your sim>' …/dd-<you> [-only-testing:MoolahubUITests/<Class>]
```

Face ID in UI tests: the iOS 26.5 simulator reports a passcode, so every money-move confirm and the app lock open the system prompt (the passcode screen when no face is enrolled, which a test can't answer). `ui-test.sh` therefore enrolls Face ID on the simulator for the run, starts a host helper that posts one simulated face per request (`UITestFaceID.answer(_:app:)` in `MoolahubUITests/UITestSupport.swift`), and unenrolls when the run ends. `MH_FACEID=0` turns this off. To try Face ID by hand: Simulator menu Features → Face ID → Enrolled, then Matching Face while the prompt is up.

`ui-test.sh` also: starts `scripts/slow-api-proxy.py` (127.0.0.1 on a free port, logs nothing) for the Home slow-server test unless `TEST_RUNNER_MH_HOME_SLOW_API` is set (`MH_SLOW_PROXY=0` skips it); starts `scripts/fault-api-proxy.py` (127.0.0.1, logs nothing) for `QAExploratoryUITests`' fault tests (a dropped connection, an unreadable 200 or a gateway 504 after a money move lands, a failed balance read) and hands them `MH_QA_FAULT_API` and `MH_QA_FAULT_MODE_FILE` (`MH_FAULT_PROXY=0` skips it, and those tests skip); checks Face ID enrollment every few seconds and enrolls again if a simulator restart cleared it; and replaces with `[redacted]` the demo password, anything typed into a secure field and the generated `Qa<Name>-…` passwords in everything it prints (XCUITest logs each `typeText`). The `.xcresult` attachments are not filtered: export only the PNGs you need and delete the bundle. `-mh-hold-toasts` (Debug) keeps every toast on screen for a placement screenshot.

Review screenshots on seeded data: `IntegrationUITests/testReviewScreensInCurrentSettings` shoots every screen read-only in the simulator's current appearance and contrast (`TEST_RUNNER_MH_REVIEW_ACCOUNT` picks another seeded account, `TEST_RUNNER_MH_REVIEW_CONTENT_SIZE=UICTContentSizeCategoryAccessibilityXXXL` shoots at AX5, `TEST_RUNNER_MH_REVIEW_SCOPE=main` only the main screens).

The copy check (DESIGN.md v2 W3, A7.4) is `MoolahubTests/CopyCheckTests.swift`: it fails the suite if a banned crypto word appears in a user-facing string outside the disclosure, About and legal, Technical details and Developer settings files, or if any app string contains an emoji (emoji appear only inside `EmojiTile`).

Done means: your scheme builds with zero errors and zero warnings, the Moolahub scheme still builds, tests pass, and your report lists files, commands and results.

## 7. Build configurations

| | Debug | Release |
|---|---|---|
| Info.plist | `Config/Info-Debug.plist` | `Config/Info.plist` |
| ATS | `NSAllowsLocalNetworking` only | no exceptions |
| `NSLocalNetworkUsageDescription` | yes | no (never uses the local network) |
| API base URL | Simulator `localhost:8787`, device `<DEV_MAC_HOST>:8787` from `Config/Local.xcconfig`, override in Developer settings | `https://api.moolahub.invalid/api` placeholder: the client refuses it and the app shows "This build isn't set up yet" |
| Developer settings, `-mh-reset-state`, dev URLs | compiled in | compiled out (`#if DEBUG`) |
| `MoolahubDevMacHost` (`$(DEV_MAC_HOST)`) | yes | no |

The two plists must stay identical apart from those three keys; `MoolahubTests/AppBundleTests.swift` enforces it.

## 8. Known limits of this foundation

- Cash out is a "not available yet" sheet (DESIGN.md v2 B2.5, J6).
- App lock relocks after 60 seconds in the background (DESIGN.md v2 B1.3, B5.4), not 2 minutes.
- Deep links are parsed (`DeepLink`) but no URL scheme or associated domain is registered (Universal Links come with the API domain).
- Passkeys need associated domains; not set up.
- `xcodebuild` prints `appintentsmetadataprocessor … warning: Metadata extraction skipped` on every build; it's a tool notice, not a compiler warning.
