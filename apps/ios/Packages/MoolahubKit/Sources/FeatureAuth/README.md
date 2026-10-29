# FeatureAuth: signed-out flow

**Owner:** Auth engineer (wave 1: lane A) · **Simulator:** `MH-Auth` · **Spec:** `apps/ios/DESIGN.md` v2 B1.13–B1.21 (and B1.0 shared rules, B1.6 and B1.9 for arrival and error banners, A8, Part W); wave 1: `features/spec/account.md` §8 to §10 (B1.13, B1.14, B1.17 and B1.19 amended)

You own every file in this folder and nothing outside it. Read `apps/ios/README.md` first.

## Keep (AppFeature calls these)
- `public struct AuthFlowView: View` with `public init(services: AppServices)`. AppFeature shows it whenever `services.session.state` is `.signedOut`, and swaps to the tabs by itself when the session becomes `.signedIn`. Do not navigate to Home yourself. The flow's `NavigationStack` is tinted ink (`Palette.ctaBackground`). Where it starts comes from Auth's `SignedOutArrival.route(for:)`; after a deactivation or deletion it is Welcome, and `AuthFlowView` is the one signed-out toast host: "Account deactivated." or "Account deleted.", once, after the root's cross-fade (B1.13 amended).

## Built (v2)
- `WelcomeView` (B1.13): wordmark on the navigation-bar row, headline and one sentence anchored above a `PinnedActionBar` with "Create account" (primary) and "Sign in" (secondary). Debug builds add the server row under "Sign in" (opens Developer settings via `services.navigator.present(.developerSettings)`); it moves into the content at accessibility sizes. Welcome hides the navigation bar, so a zero-height top `safeAreaInset` with a `canvas` background covers the status bar: at accessibility sizes the text that scrolls up stops there instead of running under the clock.
- `SignUpView` (B1.14 amended, B1.15): `MoolaTextField`s, live username check, `PickerField` date of birth opening `DateOfBirthCalendar` (system graphical `DatePicker`) in a popover, and last the optional "How did you hear about MoolaHub? · optional" (DesignSystem `PickerMenuField`, `auth.signUp.referralSource`: the seven server keys by Domain's `ReferralSourceNames`, then, after the menu's separator (`trailingOptions`), "Prefer not to say", which sends nothing); reason line ("Fill in every required field to continue." / "Fix the highlighted field to continue.") and footer prompt in the pinned bar.
- `VerifyEmailView` (B1.16) and `TwoFactorView` (B1.18): DesignSystem `CodeField`; Two-factor switches to a "Backup code" `MoolaTextField`. No reason line (A9.9 exception).
- `SignInView` (B1.17): one banner at a time (arrival `NoticeBanner` until the next attempt, replaced by an `ErrorBanner`); reason "Enter your email and password."; footer prompt.
- `ForgotPasswordView` (B1.19 amended) and `ResetPasswordView` (B1.20, reason "Enter the code and a new password."). `AuthRoute.forgotPassword(email:)` carries Sign in's email, trimmed, only when it is valid (A14); the field starts with it and no focus is forced.

## Local building blocks (`AuthComponents.swift`)
They only arrange DesignSystem components the way B1.0 lays out every auth screen; no local copies of shared components.
- `AuthScreen`: the B1.0.2 frame (scroll view, 16 pt gutter, title 12 pt below the bar, 24 pt above the pinned bar, scrolls to the top when an error banner appears).
- `AuthTitle` (`titleLarge` + `body` `textSecondary`), `AuthText.email` (the email in `headline` inside a sentence, via `@ScaledTypeFont`).
- `AuthFooterPrompt`, `ResendCodeButton` (30 s cooldown, failures go to the screen's banner), `DateOfBirthCalendar`.
- Pinned bars are `PinnedActionBar` with `DisabledReasonLine`: `hardEdge: true` at every text size on Sign up, Sign in and Reset password (B1.0.3) and on Welcome (its "Sign in" button and the Debug server row sit under the main button; at accessibility sizes the headline scrolls under the two tall buttons); `hardEdge: false` on Verify email, Two-factor and Forgot password. At accessibility sizes only the main button stays in the bar.
- A banner error (Sign in, Sign up, Reset password) scrolls the screen to the top and puts the keyboard down (`focus = nil`), so the banner and the form show and no focused field hides under the pinned bar. Code errors stay under their field and keep the keyboard.

## Rules that bite
- Every token-producing call goes through `SessionStore` (never call `API.Auth.login` yourself): it is the only code allowed to touch the Keychain.
- 401 on login/2FA/verify is a wrong entry: show the server message inline. Errors: `catch let error as APIError` or `do throws(APIError)`, then `error.message(for: .action)`.
- Clear password and code fields after every request. Never log them. `Validation` mirrors the server's rules exactly.
- Copy is final in DESIGN.md (W10); "MoolaHub" spelling; real ellipsis `…` in loading labels; no emoji in any string.
- Identifiers and tested strings are the B1.21 register. Two-factor's authenticator `CodeField` passes no identifier (B1.21 adds none); tests find it by its label "Authenticator code".
