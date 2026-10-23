# Moolahub iOS app: plan and build backlog

**Status:** Draft for founder sign-off · **Date:** 2026-10-20 · **Owner:** Jerry (CTO/PM)
**Baseline:** GitHub `main` @ `e043ef1` (2026-07-16), i.e. `docs/base-mainnet-architecture.md`. The Monad docs are superseded on main.
**How it was made:** seven role leads (product, design, iOS, backend/ledger, protocol, compliance, security), a 13-agent cross-check (9 fact-check clusters, a custody debate with a judge, a completeness critic), a frame-by-frame teardown of three reference apps (Affinity, Achieve by Petra), and a 5-area re-check against `main`. 59 external claims checked: 45 confirmed, 14 partly right (corrected here), 0 refuted. Not legal advice.

---

## 1. Decisions

| # | Topic | Call | Status |
|---|---|---|---|
| D1 | Platform | Native Swift/SwiftUI, iOS only. Min iOS 17.0, built with Xcode 26 / iOS 26 SDK (required for App Store uploads since 2026-04-28). Swift 6 language mode, strict concurrency. | Decided |
| D2 | Baseline | Build against the Base mainnet plan on `main` (8453, Privy embedded wallets, app-paid gas via EIP-7702, Privy Earn on goals, `MoolaHubCircleVault` for groups). | Decided on main |
| D3 | Launch market | Money features first for card-funded users (Ghanaian diaspora, global). Ghana residents: no-money organiser + goal tracker + waitlist until a licensed MoMo partner and BoG registration exist. | **Founder** |
| D4 | Wallet control | User is the sole owner of the Privy wallet. Moolahub may be a revocable, policy-scoped signer (Earn on `PRIVY_VAULT_ID`, fee transfer to `TREASURY_ADDRESS`) added with consent (`addSigners`, Swift SDK >= 2.10). Cash out, P2P and circle contributions are signed on device. Amends Base plan §4/§15.5 (Moolahub key as owner = custodial under Ghana Act 1154 Schedule item 3). | **Founder** |
| D5 | Identity | Moolahub session remains the API credential (email+password+2FA or passkey). Privy login once per device only to unlock the wallet. Amends Base plan §11 ("Privy access token as API auth" would let an email OTP bypass password+2FA). No SMS login/recovery. No server-verified PIN. | Recommended |
| D6 | Money moves | Server builds each Privy request; iOS signs with `generateAuthorizationSignature` after Face ID; server relays. One Idempotency-Key per confirm tap, forwarded as `privy-idempotency-key`. Money actions are online-only; show Processing until webhook/indexer confirms. | Recommended |
| D7 | Add money | Server-created provider session (MoonPay/Stripe hosted URL with destination fixed server-side) opened in `ASWebAuthenticationSession`. Privy's onramp hook is React-only. Credit only on indexer confirmation. Same API later takes a Ghana MoMo partner. | Recommended |
| D8 | Earnings | Facts only (`+$X earned`, "variable, not guaranteed") from `/earn/summary` and `/goals/:id/earnings`; per-goal opt-in with recorded consent; only in markets counsel clears; off for Ghana residents. Vault APY only on goal detail and the "How your money earns" lesson. | **Founder** |
| D9 | Groups | Compiled out of v1.0 (App Store 2.5.19 rejects hidden/dormant features). Ship as v1.1 after the CircleVault audit (Base M6/M7). | Recommended |
| D10 | Rotating payout | Restore a true ROSCA payout with protections (verified members, consented order, organizer not slot 1 by default, collateral/caps for early slots, strikes before joining). Main's escrow fix `5c3201e` pays round r about r × contribution, which removes the early lump sum. Also pick one fee model (2% on top of each contribution on main vs 2% of the pot from the recipient in Base §8). | **Founder** |
| D11 | P2P send | After v1.0: needs a transfer endpoint, payee confirmation, and a licensing view per market (Ghana Schedule item 4; US money transmission). | Recommended |
| D12 | Refer & Earn | Not in the iOS binary (App Store 3.1.5(v)); reward-free invite links only. Pause USDC commissions for Ghana users on web pending counsel. | **Founder** |
| D13 | Navigation | v1: Home · Savings · Activity · Account. v1.1 adds Groups. Liquid Glass on navigation only (`if #available(iOS 26, *)`). | Recommended |
| D14 | Look | Web brand: Space Grotesk (≤700, tabular figures) for amounts/headings via `Font.custom(_:size:relativeTo:)`, Hanken Grotesk body, IBM Plex Mono labels; tokens generated from `artifacts/moolahub-app/src/index.css`. Pinterest layout: near-black balance card with four round quick actions. | Recommended |
| D15 | Push / offline | APNs in v1 (Base plan says phase 2, but every money action confirms async). No amounts in push text. GRDB ≥ 7.9 read snapshots with as-of stamps; outbox for non-money edits only. Widgets and Live Activities in v1.1. | Recommended |
| D16 | Language | English with en-GH formatting at launch; Twi after research; other web locales after native review. | Recommended |

## 2. iOS architecture

- **Location:** `apps/ios/` in this monorepo (outside pnpm globs; add to `.replitignore`). Plain Xcode 26 project with synchronized folders; all code in one local SPM package `apps/ios/Packages/MoolahubKit`.
- **Targets:** `Domain` (pure Swift: `Money` = Int64 minor units + currency; never `Double`), `DesignSystem`, `APIClient`, `Persistence` (GRDB), `Auth`, `Wallet` (Privy, isolated with `@preconcurrency import`), `Features/{Home,Savings,Activity,Account,Onboarding}`, `AppFeature` (root + typed `Router`, one `NavigationStack` per tab, one `DeepLink` parser for Universal Links and push).
- **State:** `@Observable` `@MainActor` stores per screen; API client, sync and DB are actors; constructor injection via an `AppEnvironment`.
- **API client:** `swift-openapi-generator` from `lib/api-spec/openapi.yaml` (3.1), output committed, CI fails on drift; a hand-written `MoolahubAPI` protocol maps to Domain types. Add `securitySchemes` and the `Idempotency-Key` header to the spec. Ignore `DashboardSummary.yieldApy`.
- **Requests:** send `Content-Type: application/json` on every mutation (main's CSRF guard returns 415 otherwise), never an `Origin` header, `X-Client: ios`, `X-App-Version`, `X-Build`.
- **Auth:** Moolahub session in Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`); Face ID / device passcode app lock (`LAContext .deviceOwnerAuthentication`); passkeys via `ASAuthorizationPlatformPublicKeyCredentialProvider` with Associated Domains `webcredentials:` once the RP ID is pinned server-side.
- **Wallet:** Privy Swift ≥ 2.17 (`PrivyConfig(appId:appClientId:)`, never the app secret). After Privy login call `POST /wallet/setup`, verify the address is in the user's embedded wallets with `userCanSign == true`, else `createEthereumWallet`. Generic authorization flow: money endpoint → `{intentId, payloads[], idempotencyKey, summary}` → Face ID → sign all payloads → `POST /wallet-actions/:intentId/authorize`; persist intent + signatures before sending so retries re-send, never re-sign.
- **Vocabulary law (Base §4):** no wallet/USDC/gas/blockchain/transaction/address/hash in UI, push, widgets or intents. Exceptions: the cash-out address book, the hidden Receive screen, and About & legal (which must disclose "held as USDC, a US-dollar digital token; not a bank deposit; not insured").
- **Security:** App Attest (monitor, then enforce; reduced limits when `isSupported == false`), Secure Enclave P-256 key bound to `.biometryCurrentSet` for step-up, CA-level pinning (`NSPinnedDomains`, primary + backup SPKI) for the API host only after moving to an own domain, privacy blur in the app switcher, Universal Links only, jailbreak as a risk signal.
- **Tooling:** SwiftFormat + minimal SwiftLint; Swift Testing; swift-snapshot-testing for DesignSystem (light/dark, Dynamic Type XL); one XCUITest smoke with `performAccessibilityAudit`; GitHub Actions `macos-26` on `apps/ios/**` or spec changes; Xcode Cloud for TestFlight. Three xcconfigs (Dev, Staging, Prod) with their own bundle IDs, API URLs and Privy app/client IDs.

## 3. Backend native track (add to Base milestones C/D)

Verified against `main` @ `e043ef1`. Already fixed on main: settlement double-send (Task #82), reversal postings for failed transfers, step-up on passkey enrolment and withdrawals, CSRF on mutations, scrypt KDF for `APP_ENCRYPTION_KEY`.

| ID | Task | Why |
|---|---|---|
| N1 | Return the session token in the body for `X-Client: ios`; store a SHA-256 of tokens. Target: 15-min access + rotating refresh with reuse detection, bound to a `devices` row. | Token is cookie-only and plaintext today (`lib/auth.ts`, `schema/sessions.ts`). |
| N2 | `Idempotency-Key` middleware + `transactions.idempotency_key` unique per user; forward as `privy-idempotency-key` on every Earn/transfer call. | Base §14.5 retry queue re-calls `earnDeposit` with no key: a lost response deposits twice. |
| N3 | `/api/v1` (keep `/api` for web), RFC 9457 problem+json with stable `code`, `{amountMinor, currency}` money, cursor pagination on `/activity` and `/notifications`, `GET /v1/config` (min build, feature flags per market). | Native contract stability; 426 for old builds. |
| N4 | `GET /v1/transactions/:id` (status, legs, fee, reversal link) + `reverses_transaction_id` + `updatedAt`/status history; delta sync. | Completes the 202 + `transactionId` contract; iOS cannot flip Processing to Confirmed today. |
| N5 | Devices table, APNs (.p8 token auth), push outbox written in the same DB transaction, silent push for status refresh. | Push is phase 2 in the Base plan; iOS needs it in v1. |
| N6 | Pin `WEBAUTHN_RP_ID` and expected origins; publish AASA (`webcredentials` + `applinks`) on the production domain. | RP ID is derived from request headers today. |
| N7 | Step-up: accept a user-verified passkey assertion / Secure Enclave signature as proof; throttle step-up failures; cap 2FA challenge attempts; full step-up to disable 2FA; atomic backup-code use; TOTP last-step tracking; stop overwriting unverified registrations. | Open on main. |
| N8 | Per-user/device rate limits (not only per IP), velocity caps, 24h hold on new cash-out addresses, freeze-my-account. | Ghana CGNAT; stolen-session drain. |
| N9 | Mount `/webhooks/privy` with a raw body before `express.json` and outside the per-IP limiter; dedupe on svix id + `privy_action_id`. | Signature checks would fail; confirmations would stall. |
| N10 | Migrate `@privy-io/server-auth` to `@privy-io/node` (token verify, authorization-signature formatting, Earn). | Needed for the relay-and-sign flow. |
| N11 | Remove hardcoded `yieldApy: 4.5` from `/dashboard` and its web rendering. | Breaks "no mock data"; reads as a returns claim. |
| N12 | Append-only postings: `ON DELETE RESTRICT`, a trigger rejecting UPDATE/DELETE, generated SQL migrations, an index on postings. | Postings cascade-delete today. |
| N13 | `POST /v1/funding/sessions` → `{provider, url, orderId}` (signed, destination fixed server-side); generic `ramp_orders` + `webhook_events` so a MoMo partner plugs in later. | iOS cannot call `useFiatOnramp`. |
| N14 | Account deletion with a remaining balance: guided cash-out path before `DELETE /account`. | App Store 5.1.1(v). |

Base plan corrections to make in `docs/base-mainnet-architecture.md`: §4/§15.5 owner key (D4), §11 auth wording (D5), §15.3 policy (restrict transfers to treasury/registered destinations; the registry does not list circles), §9 push timing (D15), CircleVault per-circle no-yield mode and enforced payout order before the M6 audit, 48h timelock on registry owner changes.

## 4. iOS milestones

| M | Scope | Depends on | Done when |
|---|---|---|---|
| S0 (wk 1-2) | Privy Swift spike: login, wallet setup, `generateAuthorizationSignature`, server relay of a sponsored Base transfer with idempotency key; MoonPay/Stripe hosted session check for target markets. | Privy app for iOS client | Go/no-go written up; if no-go, re-plan wallet control before M3. |
| M1 (wk 3-5) | Xcode project, MoolahubKit, DesignSystem from web tokens + Space Grotesk, generated client, xcconfigs, lint, tests, CI. | N3 spec shape | CI green; simulator shows Home and Savings from a stub API. |
| M2 (wk 6-9) | Sign-in matrix, Keychain session, Face ID lock, passkeys, GRDB snapshots, Savings + goal detail read, Activity with pending states, `/v1/config`. | N1, N3, N6 | Airplane-mode cold start shows last balances < 300 ms with "Updated" stamp; web passkey signs in on iOS; 401 → sign-in, never a crash. |
| M3 (wk 10-13) | Add money (hosted session), Move to goal / Move to balance (relay-and-sign, 2% fee shown), Cash out with address book, push, account deletion path, About & legal. | Base M3/M4, N2, N4, N5, N9, N10, N13, N14 | Network cut mid-confirm leaves one Processing row and exactly one ledger entry; double tap moves money once; real $10 round trip on Base mainnet (dogfood). |
| M4 (wk 14-16) | Dogfood → closed TestFlight → v1.0 review kit (PrivacyInfo.xcprivacy, nutrition labels, review notes on region gating/partners/Earn roles, demo account), accessibility pass. | Gates in §5 | Submitted from the organization account. |
| v1.1 | Groups tab: create/join (Universal Link invites), trust card, round timeline with grace countdown, one-tap contribute (signed approve+contribute batch), compliance list, claim at maturity; widgets; Live Activities. | Base M5-M7 + audit, D10 | Full group lifecycle on mainnet with team money. |

## 5. Gates to real money

1. **Internal dogfood** (wk 14): Base mainnet, separate Privy app, team money, server caps, reconciliation clean 7 days.
2. **Closed TestFlight** (wk 15): invited cohort in counsel-cleared card markets; Apple organization account (D-U-N-S); terms, privacy notice, disclosures live; support desk.
3. **Public v1.0** (wk 16+): review notes, mobile/API pentest, monitoring + on-call, deletion with balance.
4. **Ghana money track** (2027 target): counsel opinion (custody, ROSCA classification, earnings), authorised MoMo partner (Yellow Card Ghana is in the SEC sandbox; HoneyCoin only with a named licensed entity), BoG registration when the portal opens, KYC by live biometric check against the NIA register (L.I. 2523; no Ghana Card images), earnings off, Data Protection Commission registration.

## 6. Open questions for the founder

1. First money-moving customer: card-funded diaspora/global now (recommended) or hold for Ghana?
2. Wallet control: user sole owner + scoped Moolahub signer (recommended) or Base §4 owner key?
3. Earnings: which markets has counsel cleared; free goal withdrawals at the target date?
4. Goals-first v1.0 with Groups in v1.1; book the audit now?
5. Rotating payout model and single fee model (D10).
6. Refer & Earn: web-only outside Ghana, non-cash credit, or retire?
7. Legal entity for the App Store account, partners and registrations (≥30% Ghanaian equity if a Ghana payments licence is ever needed).
8. Move the API to an own domain before the beta (passkeys, AASA, pinning)?
9. Fast-forward the local checkout (71 commits behind; untracked `AGENTS.md` differs from main's and blocks a fast-forward).
10. Launch languages.

## 7. Key corrections from fact-checking

- Ghana VASP Act (Act 1154) passed third reading on **12 Dec 2025** per Parliament's Votes and Proceedings (BoG's FAQ says 19 Dec); assented late Dec 2025. Schedule: custodial wallet = BoG licence. The Act has two texts on wallets: s.73 defines non-custodial in software-neutral terms, while the Schedule's item 3 describes it as cold/hardware wallets; counsel decides which governs a Privy embedded wallet (re-checked 2026-10-21, see `docs/adr-chain-base-vs-stellar.md`). Item 4 (VA payment processor) covers P2P payments.
- BoG licence application pages are still placeholders (checked 2026-10-20); full operation targeted for 2027. A June 2026 BoG notice on unauthorised USD wallets of crypto platforms was reported by secondary sources; confirm with counsel.
- App Store: hidden or dormant features fall under **2.5.19**; 3.2.1(viii) covers trading, investing and money management (loans are 3.2.2(ix)).
- Smile ID's iOS SDK (v12.3, SPM, iOS 15+) exists, but its live check against Ghana's NIA register is unconfirmed; get it in writing.
- GRDB needs **7.9+** for Swift 6.1; for the widget, prefer a small read-only snapshot over sharing the main database.
- Telecel RedSave advertises up to 8%; BezoSusu's 9% is a 2022 launch rate.
