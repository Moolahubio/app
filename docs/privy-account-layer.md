# Moolahub account layer on Privy, and the onchain backend under it

Design v2, final, 2026-10-29. The original v2 header, kept as history: written on branch `feat/ios-app`, read-only, with nothing built, run, installed, committed or signed into.

**Updated 2026-10-29 with the founder's answers** to F0, F1, F5 and F8 (decision log at the top of §1). The build now happens on branch `feat/privy-account-layer` (F0). P0 is built and committed there, with the corrections from a P0 review the same day (marked "P0 review" below).

**How to read the evidence**
- **Plan documents.** All are on `origin/feat/base-mainnet-foundation`.
  - `SPEC:n` is a line of `docs/base-build-spec-v2.md`, which calls itself "build spec v3 (final)" (SPEC:1).
  - `IOS:n` is a line of `docs/ios-app-plan.md`.
  - `ARCH:n` is a line of `docs/base-mainnet-architecture.md`.
  - `BP:n` is a line of `docs/replit-base-mainnet-build-prompt.md`.
  - SPEC, ARCH and BP line numbers are as of `8de60e4`, before the 2026-10-29 amendments. In the amended copies, SPEC lines after 158 and ARCH lines after 400 sit 2 lines lower.
- **Code paths** are relative to the repository root. Line numbers are as of 2026-10-29 and may drift.
  - `API/` = `artifacts/api-server/src/`
  - `WEB/` = `artifacts/moolahub-app/src/`
  - `DB/` = `lib/db/src/schema/`
  - `KIT/` = `apps/ios/Packages/MoolahubKit/Sources/`
- **Public documentation** is cited as `[Pn]`, listed in Appendix B. Every page was read on 2026-10-29. Documentation facts are paraphrased. There is exactly one direct quote, in F1.
- **[VERIFY]** marks anything not proven. Each one names what has to be checked, and §7 collects them all.
- **Numbering, changed from v1**:
  - Founder decisions are now **F0–F14**. v1's D1–D11 became F1–F11.
  - Build phases are **P0–P9**, plus **S0** and **UI-1 to UI-4**.
  - The spec's external items are written **SPEC-B#**, and the iOS plan's decisions **IOS-D#**.

---

## 0. Summary

**In plain words**
- **Sign-in.** Privy becomes the only way to sign in. You can use Apple, Google, a passkey, or a code sent to your email.
- **No passwords.** Privy does not offer email and password, so email sign-in is a code with no password (F1, decided).
- **Wallet.** Everyone gets one Privy wallet that only they control.
- **Second factor.** Every account sets up a passkey, or an authenticator app if passkeys don't work on the device, before its first money move (F8, decided). Sign-up offers it, but it can wait. Until it exists, our server refuses money moves, wallet export through our screens, changes to how the account signs in, email changes, and locking or unlocking. You accepted that, until then, someone with only the inbox could open the account and see its details.
- **Found after your answer (P0 review, needs your yes or no).** Our server can refuse only what passes through it. Exporting the wallet's key happens on Privy's own page, and Privy asks for a second factor only once one is set up. So before MFA, someone with only the inbox may be able to copy the key (to be checked, V34). A copied key keeps working after you set up MFA, so money added later could be taken. The F8 follow-up lists this and the other consequences, with ways to close the gap.
- **Passkey domain.** `app.moolahub.io`, for good (F5, decided).
- **What our server sees.** It never receives the Privy login token that can unlock wallets. The phone proves who you are by signing a one-time code with your wallet, and our server then gives the app its own short-lived session.
- **Gas.** Moolahub pays transaction fees through Privy. It pays only for requests our server prepared and your device approved, and only within caps that one person cannot drain.
- **Ledger.** It stays the source of truth.
- **Order of work.**
  1. Commit and push the work that was not in git (F0). Done 2026-10-29.
  2. Build the backend against fakes, and in parallel run a two-week Privy test (S0).
  3. Move to Privy's dev app (Base Sepolia), then staging (Base).
  4. Build the interface, starting with a design review.

**What your 2026-10-29 message changes**

| Topic | Current plan | Now |
|---|---|---|
| Who owns the account | Moolahub's own login stays the account, and Privy only unlocks the wallet (SPEC:20 "founder call"; IOS:17 D5) | **Privy is the account layer.** Moolahub passwords, TOTP, passkeys and email codes are retired |
| Sign-in methods | Privy email code, plus passkey MFA once per device (SPEC:142) | Apple, Google, Privy passkey, email code |
| MFA timing | "Once per device" (SPEC:142) | **Before the first money move** (F8, decided 2026-10-29). This design had recommended at sign-up for everyone |
| Email and password | — | **Not possible with Privy.** Email code, no password (F1, decided 2026-10-29) |
| Passkey domain | Not set; the repo already uses `app.moolahub.io` as production (F5) | **`app.moolahub.io`** (F5, decided 2026-10-29). This design had recommended `moolahub.io`. Staging stays `staging.moolahub.io` |
| Gas | App pays, client-side sponsorship off (SPEC:18-19) | Confirmed. Meters added that resist many fake accounts, plus a reserved budget for withdrawals (§3.9) |
| Unchanged | User is sole owner, with no Moolahub signer (SPEC:18, SPEC:110). The server never holds a Privy access token (SPEC:7). Prepare, then device verifies, signs and relays (SPEC:19). Start fresh (SPEC:34) | iOS M1/M2 interface work (IOS:71-72) moves after the backend |

**Documents to amend before any code** (P0; SPEC:3 says the spec wins on conflicts). Applied in P0 on 2026-10-29. The P0 review added dated notes to the remaining stale lines in SPEC, IOS, ARCH, BP and CLAUDE.md.
- **SPEC:** decision 4 and §2.2 (SPEC:20, SPEC:141-151), and SPEC:600 (a leaked app secret is not harmless; see §5).
- **IOS:** IOS-D5 (IOS:17) and IOS-D4 (IOS:16, Moolahub as a signer; rejected by F4).
- **ARCH, mark as superseded:**
  - :128-129: old auth carries over; the backend creates the wallet.
  - :136: an authorization key as wallet owner.
  - :396: Privy access token to middleware.
  - :399: `/auth/*`, `/security/*` and `/passkeys/*` unchanged.
  - :1504 `PRIVY_AUTHORIZATION_KEY` and :1509 `KEEPER_PRIVATE_KEY`.
- **BP, mark as superseded:**
  - :28 `KEEPER_PRIVATE_KEY` in env.
  - :75 server `POST /wallet/setup`.
  - :88 cash out with "2FA".
  - :117 `PRIVY_AUTHORIZATION_KEY`.
- **CLAUDE.md:6-7.** It still names the architecture doc as the full spec; point it at SPEC and this design.
- **One env name for the Privy webhook secret.** Keep `PRIVY_WEBHOOK_SECRET`, the name ARCH:1511 and BP:119 already use.

---

## 1. Founder decisions

### Decision log
The founder answered on 2026-10-29.

| ID | Decision | Status |
|---|---|---|
| F0 | "Yes, save and push". Committed and pushed to `feat/ios-app` | Decided and done 2026-10-29 |
| F1 | "Email code, no password" (option A, as recommended) | Decided 2026-10-29 |
| F5 | "app.moolahub.io" (option b). This design had recommended (a) `moolahub.io` | Decided 2026-10-29 |
| F8 | "Before the first money move". This design had recommended at sign-up for everyone. The founder accepted the risk that someone with only the inbox could open the account and see its details until a passkey exists | Decided 2026-10-29 |
| F8 follow-up | Consequences found after the answer (P0 review): editing or deleting the account, repeated "sign out everywhere", an attacker setting up MFA first, the length of the gap for Ghana users, and a wallet key exported before MFA that keeps working after it (V34). The rules F8 adds beyond the timing are defaults | Pending: the founder sees the corrected risk before P1 merges |
| F2, F3, F4, F6, F7, F9 to F14 | This design's recommendation | Default (founder may change) |

### F0. Save and push the work that was not in git
**Status:** Decided 2026-10-29: "Yes, save and push". Done.

**What was done (2026-10-29)**
- Five commits on `feat/ios-app`, in this order, pushed 2026-10-29:
  1. `d0eb10a` chore: ignore the local dev backend's secrets folder (`.dev/`).
  2. `8abbbbd` feat(api): server work for the native iOS app's first feature wave.
  3. `a2e5353` fix(web): dashboard group card shows an active group only.
  4. `db59ef6` chore(dev): one-command local backend for the iOS dev build (`scripts/dev-ios-backend.sh`).
  5. `49bb75e` feat(ios): native SwiftUI app (iOS 17+), first feature wave.
- Rebased onto `origin/feat/base-mainnet-foundation` at `8de60e4` (draft PR #36's branch). Root `pnpm run typecheck` exited 0 afterwards.
- Before publishing, the iOS design spec (`apps/ios/DESIGN.md`) was kept private (gitignored), and the dev Mac's name moved to a gitignored local setting.
- Branch `feat/privy-account-layer` was cut from `49bb75e`. P0 is committed there (7 commits) and was pushed on 2026-10-29 after a check for anything that should not be public. P1–P9 follow on the same branch.
- **Public repository.** `Moolahubio/app` is public (https://github.com/Moolahubio/app shows it as Public without signing in, checked 2026-10-29), so the secret scan (recommendation step 1) ran on the whole history before the push.
- **Secret scan (2026-10-29).** The fallback scanner (`scripts/secret-scan.mjs --history`) read every commit reachable from every local branch, tag and remote-tracking branch (266 commits, the five included) and found no real secret, before and after the P0 review added rules; the P0 files are clean too. Pull request refs that exist only on GitHub were not part of that scan; the CI full-history scan reads them (§2). gitleaks itself did not run before the push; it runs in CI.
- **GitHub secret scanning and push protection** are both on for the repository (checked 2026-10-29 with the GitHub API; V19).

**The facts at design time** (kept as history)
- The iOS app was not in git: `git ls-tree -r HEAD -- apps` listed 0 files.
- 39 files of backend and app changes were not committed (`git diff --stat HEAD`: 3,020 lines added). They included the iOS session path at `API/lib/auth.ts:96-114`.
- The `.dev/` ignore rule existed only as a local edit, not in git (`.gitignore:54-55`).
- `scripts/dev-ios-backend.sh` was not in git.
- `feat/ios-app` was 2 commits behind draft PR #36's branch (`git log HEAD..origin/feat/base-mainnet-foundation`: 8de60e4, 73871da).

**Recommendation**, in this order (accepted):
1. Run a secret scan on the files as they are.
2. Commit the `.gitignore` change first, then the iOS app, the backend changes and the dev script.
3. Rebase onto `origin/feat/base-mainnet-foundation`.
4. Build P0–P9 on a new branch `feat/privy-account-layer`, cut from there, as a new PR that depends on PR #36.

Whether #36 merges first is your call (still open). This design recommends yes, because #36 carries the signed-off spec amendment.

**Blocks:** nothing.

### F1. "Email and password" is not possible with Privy as asked
**Status:** Decided 2026-10-29: A, "Email code, no password".

**The facts**
- Privy says: "We do not support regular password-based verification." [P1]
- Privy's email sign-in sends a one-time code, valid for 10 minutes [P3].

**Options**

| Option | What users see | Good | Bad |
|---|---|---|---|
| **A. Email code, no password (recommended, chosen)** | Type your email, then the code. Apple, Google and passkey appear on the same screen | One account system. A password adds little, because "forgot password" goes to the same inbox | Someone with your inbox can start a sign-in. Once a passkey exists, F8 stops them: the new phone also needs your passkey before anything works. Before that, they can open the account and see its details (the risk accepted in F8) |
| B. Keep Moolahub's own email + password next to Privy | Two sign-ins | Familiar | Not "Privy as the account layer". The password protects nothing about the wallet. We keep all the old password, reset and 2FA code (`API/routes/auth.ts:160-551`) |
| C. Moolahub becomes a "custom login provider" (JWT) | Our password screen | Keeps passwords | Privy would trust tokens we create, and a user token can be traded for wallet control [P5], so Moolahub could reach user money. That breaks SPEC:7. Privy must also grant access first [P4]. The spec already rejects it (SPEC:20) |

**Recommendation:** A. Chosen 2026-10-29.

**Blocks:** sign-in screens, the schema, P1 (now unblocked by this decision).

### F2. How each request proves "it's you"
**Status:** default (founder may change).

**Recommendation (unchanged): our own session.**
- At sign-in, our server checks a proof once (F3), then gives the app a random session key. It stores only a fingerprint of that key.
- The alternative, checking a Privy token on every request, is rejected for two reasons:
  - That token can be traded for wallet control by any server holding our app secret [P5, P6].
  - Freezing a Privy user does not cancel tokens already issued [P27].

**Default lengths** (configuration, not a decision for you):
- **iOS:** a 15-minute access key, plus a 30-day refresh key tied to the device (IOS:49).
- **Web:** 24 hours idle, 7 days at most.
- Neither is longer than Privy's own 30-day default session [P8].

**Two clarifications added**
- **Phone locked.** The refresh key is readable only while the phone is unlocked. The short access key is readable after the first unlock, so a background status check can run for up to 15 minutes. A silent push only marks data as stale, and the app refreshes when it is next opened.
- **Two sessions to keep in step.** Our session and Privy's: §3.4 and §3.7 have the rules.

**Blocks:** P1.

### F3. What the phone shows our server at sign-in
**Status:** default (founder may change).

**Recommendation (unchanged): a wallet signature.**
1. The app asks our server for a one-time code, and the wallet signs it on the device.
2. Our server checks the signature and asks Privy which user owns that wallet [P11].
3. No Privy login token ever reaches us.

**What changed**
- **One passkey prompt per new session, once MFA is set up.** Signing is then protected by MFA, so each new session costs one passkey prompt unless the person passed MFA in the last 15 minutes [P22]. Before MFA is set up (F8), we expect the signature to need no prompt, which is why an inbox alone can open such an account (our reading of [P21]; to be checked, V33).
- **Billing.** Each sign-in also counts as one wallet signature toward Privy's billing (F11).
- **The identity-token alternative is not built** until Privy confirms in writing that identity tokens cannot be traded for wallet control (V1). Only the interface that would allow it later is written.

**Blocks:** P1, S0.

### F4. Things the server starts by itself
**Status:** default (founder may change).

**Recommendation (unchanged).**
- No Moolahub key on any user wallet.
- Auto-save into an earning goal is a one-tap confirm (SPEC:24).
- Auto-save into a cash goal is a ledger move with no transaction (SPEC:163).
- The circle "keeper" key lives in a cloud key vault, never in env, and only from v1.1.

**Reasons**
- Privy's docs disagree on what a signer without a policy may do: React says no limits apply, while Swift and Android say the wallet's default rules apply [P69].
- A server key in a 1-of-k owner group can export the wallet by itself [P45].

This also rejects IOS-D4 (IOS:16, Moolahub as an optional signer).

### F5. The passkey domain (the one name you can never change)
**Status:** Decided 2026-10-29: (b) `app.moolahub.io`. This design had recommended (a) `moolahub.io`; that recommendation and its reasons are kept below as history.

**What this decision means**
- Production passkeys are made for `app.moolahub.io` and are tied to that one host forever. They do not work on any other `moolahub.io` host, such as a marketing site on the apex.
- The Apple file is served at `https://app.moolahub.io/.well-known/apple-app-site-association`, directly, as JSON, with no redirect [P18]. The same Replit deployment already serves the app there (`.replit:95`, `:112`).
- The iPhone app is set up for the same name in production (settings in §2 and §4; exact format: V9).
- Staging is unchanged: `staging.moolahub.io` stays its own passkey domain, used by dev and staging (F6).
- Publish the production file at least a day before production passkeys are tested [P18].

**The facts**
- The repo already treats `app.moolahub.io` as production:
  - `.replit:95` and `:112` (`APP_URL`, `PUBLIC_APP_URL`);
  - `WEB/../index.html:13`;
  - emails come from `noreply@moolahub.io` (`.replit:94`).
- On 2026-10-21 those hosts showed Replit's "not live yet" page (`docs/build-audit-2026-10-21.md:15`).
- A passkey only works for the domain it was made under. The iPhone app needs an Apple file served from that domain over HTTPS with no redirects [P18].
- Apple's servers fetch that file within about a day, and phones re-check it about weekly [P18]. Changing the domain later means every user makes a new passkey.

**Options** (as offered; (b) was chosen)
- **(a) Recommended at the time: `moolahub.io`.** Passkeys then also work on any `*.moolahub.io` site. The condition: `https://moolahub.io/.well-known/apple-app-site-association` must answer directly, never redirecting to `www` or `app`.
- **(b) `app.moolahub.io` (chosen).** Simpler, because the same Replit deployment already serves the app there. The cost: passkeys are tied to that one host forever.

**Also:**
- Serve production only on your own domain, not on `*.replit.app`.
- Staging uses `staging.moolahub.io` as its own passkey domain.

**Still needed from you**
- Who holds the registrar account and DNS.
- Whether the apex will host a marketing site. This no longer affects passkeys.

**Blocks:** passkeys (iOS and web), Google brand verification (F11), the App Store build. The domain choice no longer blocks them; the DNS owner and the published Apple file still do.

### F6. Environments and hosting
**Status:** default (founder may change). The passkey domain column follows F5, decided.

**Proposal**

| Env | Chain | Privy app | iOS bundle ID | Database | Hosting | Passkey domain |
|---|---|---|---|---|---|---|
| dev | Base Sepolia (84532 [P77]) | "Moolahub Dev" | `io.moolahub.app.dev` | local `supabase start` (SPEC:787) | engineer laptop | `staging.moolahub.io` |
| staging | Base 8453 | "Moolahub Staging" | `io.moolahub.app.staging` (new) | Supabase staging org | Replit deployment + a separate always-on VM for the worker | `staging.moolahub.io` |
| prod | Base 8453 | "Moolahub" | `io.moolahub.app` | Supabase prod org | Replit deployment + worker VM | `app.moolahub.io` (F5, decided) |

**The facts behind it**
- Privy recommends one app per environment [P53], and `reference_id` is unique per Privy app (SPEC:791).
- The iOS plan wants three configurations, each with its own bundle ID (IOS:41).
- Today every build uses `.dev` (`apps/ios/project.yml:57`).
- Replit deploys as "autoscale" today (`.replit:5`), but the worker must run on its own Reserved VM (SPEC:667).
- Web (`/`) and API (`/api`) share one host (both `artifact.toml` files), which our secure session cookie needs.

**Changed from v1:** the staging host must be live **before** P6, because dev passkeys use its domain.

**Blocks:** every credential in §2.

### F7. Fresh start, and what happens to today's demo
**Status:** default (founder may change).

**Recommendation**
- New databases with no old users (SPEC:34). Testers sign up again.
- Before P1 merges, export the old Replit database encrypted, keep it 30 days, then destroy it.
- Old Monad keys, the platform key and the Monad addresses in `.replit:92-107` (classified by type, values not printed) never reach a new environment.
- **New:** the current demo is frozen as a git tag on its old Replit deployment and old database, so you can still show it. New environments run only the new sign-in. Until the new screens ship:
  - the new web app shows "We're upgrading sign-in";
  - iOS dev builds use a plain test sign-in screen (P6).

**We need from you:** OK to tell testers, the 30-day retention, and the demo freeze.

**Blocks:** P1 merge, P2.

### F8. Second factor before the first money move
**Status:** Decided 2026-10-29: "Before the first money move". This design had recommended "at sign-up for everyone"; that recommendation and its reasons are kept at the end of this section as history. You accepted the risk shown in the question: "someone with only your inbox could open the account and see your details until a passkey exists".

**The facts**
- Privy's MFA protects using the wallet (signing, export, recovery on a new device), not signing in [P21]. It applies once the user has set it up [P21]; before that, nothing at Privy asks for a second factor.
- Key export is a Privy screen on Privy's own web address, open to the wallet's owner unless a policy denies it [P44]. Our server never sees it, so it cannot refuse it. The spec's user policy allows export on purpose, so people can always leave (SPEC:137).
- MFA must be passed again after 15 minutes [P22]. A dashboard setting controls this window [P21; range V10].
- A passkey can be MFA only if passkeys are also a sign-in method [P20].
- Users can switch MFA off themselves, which itself needs MFA [P20, P22].

**What this means.** You decided the timing: MFA before the first money move. The rules below are this design's defaults (founder may change).
- Sign-up is: Privy sign-in, then wallet, then our session, then the profile. At the end, sign-up offers MFA ("Set up a passkey now", or later), and the app keeps reminding until it is done.
- MFA must be set up before the first action in the list below. The app runs MFA setup at that moment, then goes back to the action.
- A passkey first; an authenticator app if the device can't make passkeys. No SMS anywhere.
- If MFA later disappears, every action in the list is blocked again and the user is told (§3.5).
- Ghana users have no money features (SPEC:10), so they may never set up MFA. For them the gap lasts as long as they use the app, and the app keeps offering MFA. This length was found after your answer (F8 follow-up).

**Needs MFA set up first** (default, founder may change). Our server refuses each of these until a second factor is set up; the app explains and starts the setup (how: §3.4 and invariant 7). The server can refuse only what passes through it: a key export on Privy's own page does not (see the F8 follow-up).
1. **Every money move:**
   - starting Add money (an on-ramp session), and showing a deposit address;
   - every Earn deposit or withdraw;
   - every request whose gas we pay, both when our server prepares it and when the phone confirms it (§3.9);
   - moving money into or out of a goal, and breaking a lock;
   - cash out and adding a cash-out destination, if cash out ships;
   - circle contributions (v1.1).
2. **Wallet export** through our screens (A21, [P44]). Privy's own export page is not ours to gate.
3. **Adding or removing a sign-in method** through our screens. Two exceptions: the passkey that MFA setup itself links [P20], and the first email on an account that has none (a passkey sign-up finishing its profile).
4. **Changing the email.**
5. **Locking and unlocking** (F14) exist only once the account has MFA. Before that our screens put no money in, and setting up MFA is the stronger step, because it signs out every other device.
6. **Turning MFA off or changing MFA methods.** Privy also asks for MFA itself here [P20, P22].

**Does not need MFA** (default, founder may change): signing in; finishing and editing the profile; reading balances, goals and activity; creating goals and using a goal as a tracker; learn, streaks and notifications; sign out and sign out everywhere; deleting the account. Deletion stays open because in-app deletion is required [P31], and asking someone to set up a passkey in order to leave would get in the way.

**When MFA is set up for the first time** (default, founder may change; through our screens, or detected at Privy, §3.5)
- The account is marked as having MFA (§3.2), and a security event is recorded.
- Every other session is revoked. Other devices must sign in again, which now needs the passkey (F3).
- A notice goes to the email and by push to every other device.
- If MFA was set up on a device other than the one that created the account, the account-wide hold (§3.5) starts and money moves also wait out its 72 hours. The notice offers the emailed lock link (F14). This can also delay a real person who signed up on one device and set up MFA on another, so the app says so before setup.
- The same rules apply whenever MFA goes from none back to set up.

**What someone with only your inbox can and cannot do.** "Accepted" is the risk you accepted in your answer. "Pending" marks what the P0 review found after your answer, which waits for your yes or no (F8 follow-up).

| | Before you set up MFA | After you set up MFA |
|---|---|---|
| Start a sign-in with the email code | Yes | Yes. Privy MFA protects the wallet, not sign-in [P21] |
| Get a Moolahub session | Yes. The sign-in proof is a wallet signature (F3), and with no MFA nothing asks for a second factor on a new device (our reading of [P21]; V33) | No. That signature is signing on a new device, which needs your passkey [P21]. Sessions opened before MFA were revoked when you set it up |
| See your details: name, username, email, birth date, residence, goals, activity | **Yes. Accepted** | No |
| Edit the profile, or delete the account | Yes. **Pending.** Deletion loses the profile and goal history | No |
| Use "sign out everywhere", again and again | Yes. **Pending.** It keeps signing you out; you sign in again | No |
| Export the wallet's key on Privy's page (Privy's export screen, or the exit page, A21) | **Possibly. Pending, and the most serious.** Our server cannot refuse it, and Privy's MFA does not guard it yet [P21, P44]; whether a session with no MFA can export is V34. A key copied now keeps working after you set up MFA | No new copy: export needs your passkey [P21]. A key copied before MFA still works |
| Move money, get gas paid, export through our screens, add or remove a sign-in method, change the email | No. Our server refuses each until MFA is set up | No. Each also needs a wallet signature, which needs your passkey |
| Lock the account, or start an unlock | No. Lock and unlock exist only once MFA is set up | Lock: yes, by the emailed link, which is defensive (F14). Unlock: they can start it, but finishing needs your passkey (F14) |
| Set up their own MFA before you do | Yes. **Pending** (the second worst case, below) | No. Changing MFA needs MFA [P20, P22] |
| Link a method or change the email at Privy, outside our screens | Possibly, because Privy documents no MFA for linking [P23]. Detected, with a hold and notices (§3.5) | The same: detected, not prevented (§3.5) |

**F8 follow-up: the worst cases** (found after your answer; pending your yes or no)
1. **A key copied before MFA.** If V34 shows that a Privy session with no MFA can export the key, someone with only your inbox could copy it before you set up MFA. Nothing tells you. The copy keeps working after MFA, so money you add later could be taken. Nothing in this design stops that today; the options are below.
2. **They set up MFA first.** They then hold the account. Your devices are signed out, and your next sign-in asks for their passkey. Our screens have put no money in, because they put none in without MFA. You are told by push on your phone and by email. Their setup came from another device, so the 72-hour hold stops them moving money through an account in your name, and the emailed lock link freezes the account for both of you. Getting the account back is the same open question as a lost passkey (V16).

**Ways to close the key-copy gap** (for you to choose, if V34 confirms it)
- (a) A Privy policy that denies export until MFA is set up, then allows it, if Privy can express that and change it safely (V34). Export must stay possible once MFA exists (SPEC:137).
- (b) A fresh wallet for money: before the first money move, right after MFA setup, the account gets a new wallet and the first one is never funded. This changes "one Privy user, one wallet" (invariant 3) and Privy's "no second wallet" setting (§3.8).
- (c) MFA at sign-up for everyone, this design's original recommendation (below).
- (d) Accept the risk as it now reads.

**Mitigations** (also in §5)
- Sign-up offers MFA straight away and the app reminds until it is done, so most accounts never have the gap.
- Nothing in our screens puts money into an account without MFA, and the server pays no gas for it (§3.9). So, before MFA, the account holds no money that came through Moolahub. That does not cover worst case 1: a copied key outlives MFA.
- The server, not the app, enforces the list above, for every action that passes through the server.
- Every sign-in on a new device sends a notice (§3.15).
- The first-setup rules above: other devices signed out, notices, and the hold with a lock link when another device set it up.

**Recommended at the time** (v2, not chosen; kept as history)
- **Why v1 was wrong.** v1 enrolled the passkey only before the first money move. In between, someone with only the inbox could open the account, change settings and see personal data. Ghana users are tracker-only and might never move money at all (SPEC:10).
- The sign-up flow was: Privy sign-in, then wallet, then passkey linked and enrolled as MFA, then our session.
- If the device can't make passkeys, an authenticator app is accepted instead.
- Until MFA exists, the server gives only an "onboarding" session that can do nothing beyond finishing the profile and setting up MFA.
- If MFA later disappears, money is blocked and the user is told (§3.5).
- No SMS anywhere.

Your choice returns to v1's timing. What is new is the exact list above, enforced by the server, and the first-setup rules.

**Blocks:** was blocking onboarding, P1 and P3; unblocked 2026-10-29. The F8 follow-up (the pending consequences and V34) goes back to you before P1 merges.

### F9. Duplicate accounts (same person arrives by email, then Google)
**Status:** default (founder may change).

**The facts**
- Privy documents no automatic merge.
- A third-party report shows a second user and a second wallet created for the same address [P61].
- Privy's "account transfer" exists only in the iOS and Android SDKs. It leaves the old wallet with a deleted account [P24].
- Privy will not link a sign-in method that already belongs to another Privy user unless transfer is turned on [P24].

**Recommendation**
1. Never auto-merge.
2. If a new sign-in brings an email that another Moolahub account already has, stop and say which way to sign in.
3. **New:** to free the Google or Apple account so it can be added to the real account, the stray Privy user is deleted. Three checks come first:
   - the person signs the request with the stray wallet;
   - our worker confirms that wallet never held anything (no USDC, no vault shares, never sent a transaction);
   - the stray has no Moolahub account.
   Then the person signs in the usual way and adds Google in Settings. This works on web and iOS alike.
4. Transfer stays off.

**Blocks:** P1, P3.

### F10. The website at launch (changed from v1)
**Status:** default (founder may change).

**The fact.** Signing in on the web under F3 loads the Privy wallet in the browser. If any script on our page is hijacked (XSS), it can ask that wallet to sign anything, whatever our screens allow (SPEC:45). So "the web is read-only" protects nothing.

**Options**
- **(a) Web without a wallet.** You sign in on the web by approving a QR code from the iPhone app. Safest, but Android-only users cannot use Moolahub at all until there is an Android app.
- **(b) Web with the wallet, after hardening (recommended).** Requirements:
  - a strict Content Security Policy header (Replit static hosting can send response headers [P78]; V27 checks our config file);
  - the inline scripts in `index.html` (from line 27) moved out;
  - no third-party scripts;
  - the user-owned Privy policy (SPEC:132; V8) before any web wallet loads;
  - MFA on every signing, once MFA is set up. Before that (F8), the web wallet signs without it, but our screens put no money in and pay no gas (a key exported before MFA is the F8 follow-up, V34).

  Web money moves still wait for S0 (SPEC:151).

**Also:** Apple sign-in on the website may have to wait until the iPhone app is in the App Store [P72; V23].

**Blocks:** web scope, P1 (the shape of the sign-in proof).

### F11. Gas budget and Privy plan
**Status:** default (founder may change).

**The facts** [P52]

| Tier | Monthly active users | Price per month |
|---|---|---|
| Free | 0–499 | $0 |
| Core | 500–2,499 | $299 |
| Scale | 2,500–9,999 | $499 |

- **Pay-as-you-go.** It starts once a month passes 10,000 active users **or** 50,000 wallet signatures. It costs a $2,000 base fee, plus $0.05 per user over 10,000 and $0.01 per signature over 50,000.
- **What counts as a signature:** any signature request from a Privy wallet.
- **Monthly signature estimate:** users × (sign-ins + step-ups + money moves × signatures per move). How Privy counts our device-side approval signatures is V14.
- **Plans and features:**
  - The pricing page shows the policy engine and key quorums as "available as add-on"; which plan is unclear (V14).
  - Customising Privy's login email is offered to Enterprise customers [P2], so on lower plans the code email is likely Privy-branded.
  - Webhooks in production need Enterprise [P50].
  - Gas costs network gas plus an unpublished convenience fee [P39], paid from prepaid credits with a saved card on mainnet [P38].

**Decide**
- The monthly gas budget.
- The plan.
- Whether you need Enterprise at launch, for branded login emails or webhooks.
- When to turn on Privy's automatic credit refill [P63].

**Recommendation**
- Start prepaid with Privy's low-credit notices on.
- Leave auto-refill off until staging shows real costs.
- Polling works without webhooks (SPEC:26).
- Default caps (configuration) are in §3.9.

**Blocks:** P6, P8.

### F12. How many prompts per money move (new)
**Status:** default (founder may change).

**The fact.** A money move needs our own Face ID approval, the device check, and Privy's passkey MFA if more than 15 minutes have passed [P22]. On iPhone a passkey prompt is itself a Face ID sheet.

**With F8 decided.** Every money move happens with MFA set up. The very first one starts with MFA setup, then this pattern applies. Whether setup itself counts as a passed MFA, so the move right after needs no Privy prompt, is V32.

**Options**
- **(a) Exactly one Face ID per move (recommended if S0 shows it is possible).** Skip our own Face ID whenever Privy's prompt will appear (V26).
- **(b) Our Face ID always, plus Privy's when its window has lapsed.**

**Recommendation:** (a) if possible, else (b). Keep Privy's window at 15 minutes.

**Blocks:** UI-3.

### F13. The App Review account (new)
**Status:** default (founder may change).

**The facts**
- Apple needs a working demo account or an approved demo mode [P30, guideline 2.1(a)].
- Privy test accounts work only with email or SMS sign-in [P29]. Whether they work on production apps is V12.
- Under F8 (decided), an account without MFA cannot reach money moves. The review account therefore has MFA set up, so the reviewer can try every screen, and a reviewer's new device will ask for MFA at sign-in.

**Options**
- **(a) Recommended.** A dedicated review account with a fixed email code [P29], an authenticator app as MFA whose setup key goes in the review notes, at most $20 of team money, and tight caps.
- **(b)** A built-in demo mode, with Apple's prior approval [P30].

**Blocks:** P9, submission.

### F14. "Lock my account" replaces "deactivate" (new)
**Status:** default (founder may change).

**The facts**
- Today deactivation undoes itself at the next login (`DB/users.ts:31-33`).
- Lock also freezes the account at Privy, which revokes sessions and blocks sign-in while keeping the wallet unchanged [P27].
- A frozen user cannot sign in, so they cannot prove anything through Privy.

**Recommendation**
- **Only once MFA is set up** (F8, decided). Before that there is no money to protect, and setting up MFA is the stronger step, because it signs out every other device. This also stops someone with only the inbox from locking an account its owner could then never unlock.
- **Lock:** from the app (signed by the device), or from a link sent to your email.
- **Unlock:** from an emailed link, then a 72-hour wait with notices on every channel, then Privy unfreeze, then normal sign-in. That sign-in needs your passkey on a new device [P21], which always exists here because lock needs MFA.
- Support can neither lock nor unlock, so Moolahub never decides who reaches their own money.

**Residual risk:** a thief who knows the phone's passcode and has the email app on it could start an unlock. The 72 hours give the owner time to re-lock.

**Blocks:** P3.

---

## 2. Credentials and setup you provide

**Golden rule**
- **Public IDs** can be pasted in chat.
- **Secrets** are never pasted into chat, issues, PRs, Slack or email. You put each secret yourself into Replit Secrets, a GitHub environment, or the Privy dashboard.
- **Engineers' laptops** keep secrets in gitignored files with mode 600:
  - `.dev/api.env` for the existing offline demo;
  - `.dev/privy-dev.env` for the new Privy dev launcher (§4).
- **Nothing secret** ever goes into the iPhone app or the website. They need only the public Privy app ID and app-client ID (IOS:38; [P34]).

| # | Item | What it is | Secret? | Where you get it | Where we keep it |
|---|---|---|---|---|---|
| 1 | Privy account, 3 apps | Sign-in and wallets, one app per environment (F6) | App ID public | Privy → Configuration → App settings → Basics [P53] | Server env, web build `VITE_PRIVY_APP_ID`, iOS config |
| 2 | Privy **app secret** ×3 | Our server's password to Privy. If lost, it can't be recovered and must be regenerated [P53] | **SECRET** | Same page [P53] | The **worker** deployment's Replit Secrets only (§5) |
| 3 | Privy **read-only app secret** ×3 [VERIFY V25] | For the web/API service, which only reads users. Privy advises read-only secrets for read-only services [P68] | **SECRET** | Privy dashboard [V25] | API deployment's Replit Secrets |
| 4 | Privy **iOS app client** per app | Allowed bundle ID (an empty list denies everything), URL scheme, Apple client ID = bundle ID, session length [P15] | Public | App settings → Clients [P15] | iOS config |
| 5 | Allowed web domains per app | Production domain only; remove test domains in prod [P68] | Public | App settings | Privy |
| 6 | **Allowed OAuth redirect URLs** per app | Exact `https://` URLs, no wildcards. With none listed, Privy redirects anywhere [P67] | Public | Configuration → App settings → Advanced [P67] | Privy |
| 7 | Sign-in methods | Email, Google, Apple, Passkey on; SMS, external wallets and guest off. MFA: passkey plus authenticator app [P3, P20] | Setting | Login methods | Privy |
| 8 | TEE mode | Required for gas sponsorship [P38]; may need "request access to migrate" [P37] | Setting | Wallets → Advanced | Privy |
| 9 | Gas sponsorship | Sponsor gas fees on. Chains: Base Sepolia (dev), Base (staging/prod). **Client transactions off** [P38] | Setting | Fee sponsorship | Privy |
| 10 | Billing | Card, prepaid credits, low-credit notices, auto-refill decision (F11) [P38, P63] | Account | Billing → Fee sponsorship [P63] | Privy (you only) |
| 11 | Privy **webhook secret** ×3, as `PRIVY_WEBHOOK_SECRET` | Proves a webhook came from Privy. URL: `https://<host>/api/webhooks/privy` | **SECRET** | Configuration → Webhooks [P50] | Worker secrets |
| 12 | Privy branding | App name, logo, terms and privacy links [VERIFY fields, V30] | Public | Dashboard | Privy |
| 13 | Privy test accounts | Fixed email and code for review and tests [P29] | Code **SECRET** | User management → Authentication → Advanced [P29] | Your password manager; App Store review notes |
| 14 | Apple **organization** developer account | Finance apps should come from a company, not a person [P30, 5.1.1(ix)]. Confirm that team `96X7N58MVV` (`project.yml:19`) is a company account; if not, get a D-U-N-S number (SPEC-B10; IOS:80) [VERIFY] | — | developer.apple.com | Apple |
| 15 | Apple App IDs: `io.moolahub.app` (primary), plus `.dev` and `.staging` grouped under it [P72] | Capabilities: Sign in with Apple, Associated Domains, Push Notifications | Public | Identifiers | Apple |
| 16 | Apple **Services ID** | Apple sign-in on the web. Return URL `https://auth.privy.io/api/v1/oauth/callback` [P3]. May need the app in the App Store first [P72; V23] | Public | Services IDs | Privy dashboard |
| 17 | Apple **Sign in with Apple key (.p8) + Key ID** | One key for the app group (at most 2 per primary app: one in use, one spare for rotation [P72]) | **SECRET** | Apple → Keys | Pasted only into each Privy app's dashboard; original in your password manager |
| 18 | Apple **push key (.p8) + Key ID** | Lets our server send push notifications (IOS:53 N5) | **SECRET** | Apple → Keys | Worker secrets |
| 19 | Apple private-email relay | Register our sending domain (SPF and/or DKIM) so "Hide My Email" users get our emails [P72] | Setting | Sign in with Apple for Email Communication | Apple |
| 20 | Apple sign-in server notifications | Apple asks apps to handle account changes this way [P31, P72]. Needed only if Privy doesn't (V13) | Setting | Apple | Apple |
| 21 | App Store Connect app record and privacy labels | Must cover what Privy, Apple and Google receive | — | App Store Connect | Apple |
| 22 | **Google OAuth client** (Web app type, redirect as in #16) | Google sign-in with our credentials [P3] | ID public, client secret **SECRET** | Google Cloud Console | Privy dashboard only |
| 23 | Google domain verification, homepage, privacy policy | Required for Google to show "Moolahub" on its consent screen [P65, P66]. **Whether this can pass while the redirect is on `auth.privy.io` is unproven (V22).** Until then, expect Google's screen to show a domain, not our name | — | Google Search Console, our website | Google |
| 24 | **Domain** and DNS owner. Passkey domain decided: `app.moolahub.io` in production (F5); `staging.moolahub.io` for dev and staging | Passkeys, AASA, email | Public | Registrar | DNS |
| 25 | Email sending: Resend key, plus SPF, DKIM and DMARC records on `moolahub.io` | Product and security emails (`API/lib/email.ts:8-9`) | Key **SECRET** | Resend, DNS | Worker secrets |
| 26 | `apple-app-site-association` file | At `https://app.moolahub.io/.well-known/apple-app-site-association`, listing `96X7N58MVV.io.moolahub.app` (prod); at `https://staging.moolahub.io/.well-known/apple-app-site-association`, listing `.dev` and `.staging`; both under `webcredentials` [P16, P18] | Public | We write it | Web app `public/.well-known/`, served as JSON with no redirect [P78; V27] |
| 27 | Replit deployments per environment | API + web on one host; worker on a Reserved VM (SPEC:667); custom domains | Account | Replit | Replit |
| 28 | Base RPC keys: Base Sepolia (dev); Base (staging, prod) | Our server's link to the chain | **SECRET** (the URL holds a key) | Provider of your choice (SPEC-B10) | Laptop file / worker secrets |
| 29 | Test money | Base Sepolia test USDC (P6); about $20 of real USDC on Base for staging (P8) | — | Faucet / team | Team wallet |
| 30 | Earn prerequisites (staging) | Key ceremony and Safes (SPEC-B4, about 2 weeks; SPEC:775); quorum-owned admin wallet; throwaway wrapper ($100 cap); `PRIVY_VAULT_ID` (SPEC:239-245, SPEC:788) | Key shares **SECRET** | Privy + signers | Hardware or KMS (SPEC:111) |
| 31 | Supabase database URLs (staging, prod) | Databases (SPEC-B1) | **SECRET** | Supabase | Replit Secrets; GitHub environment for migrations (SPEC:664) |
| 32 | `APP_ENCRYPTION_KEY`, `OPERATOR_TOKEN` per environment | Upload tokens, operator console | **SECRET** | Engineer generates | Replit Secrets |
| 33 | Sentry DSN; `SENTRY_AUTH_TOKEN` | Error reporting (SPEC:733) | Token **SECRET** | Sentry | Server env / CI |

**Order to follow**
1. F0 and F5 are decided (2026-10-29), and F0 is done. Name the DNS owner (F5). Check #14.
2. Create the staging Replit deployment with `staging.moolahub.io`, and publish the AASA file at least a day before passkey tests [P18]. Staging stays the passkey domain for dev and staging.
3. Create the Privy dev app (#1–#13). Use Privy's default Google credentials for now [P3].
4. Do #15–#17, then add Apple to the dev app **with custom credentials only**. Privy cannot switch Apple from its default credentials to custom ones later [P3].
5. Do #22–#23 and #25.
6. Do #28 and #29 (Base Sepolia).
7. Set up staging: the Privy staging app, Supabase, the Base RPC, credits, and #30.
8. Set up production last, after steps 1–6 are done. Publish the AASA file at `https://app.moolahub.io/.well-known/apple-app-site-association` at least a day before production passkey tests [P18].

**Keeping secrets out of git**
- **Add to the root `.gitignore`** (today it has no env pattern):
  ```gitignore
  # Secrets: never commit
  .env
  .env.*
  !.env.example
  *.env
  .envrc
  .dev/
  *.pem
  *.p8
  *.p12
  *.pfx
  *.key
  *.keystore
  *.jks
  *.mobileprovision
  id_rsa*
  id_ed25519*
  *service-account*.json
  apps/ios/Config/*.xcconfig
  !apps/ios/Config/Env.example.xcconfig
  ```
  The P0 review added `.envrc`, SSH keys, keystores, `*.pfx`, service-account files and every iOS build config except the example. `*.key` also hides Keynote files.
- **Rewrite the tracked root `.env.example`.** Its names included `DEPLOYER_PRIVATE_KEY`, `PLATFORM_PRIVATE_KEY`, `MONADSCAN_API_KEY` and `MONAD_TESTNET_RPC_URL` (names read; values not read). Keep only names that are still in use, and no private-key names (done in P0).
- **Per-package examples, names only:**
  - **API**, `artifacts/api-server/.env.example`:
    - Privy: `PRIVY_APP_ID`, `PRIVY_APP_SECRET`, `PRIVY_APP_SECRET_READONLY`, `PRIVY_WEBHOOK_SECRET`, `PRIVY_VAULT_ID`
    - Chain and web: `BASE_RPC_URL`, `CHAIN_ID`, `APP_ORIGIN`, `ALLOWED_ORIGINS`
    - Database and keys: `DATABASE_URL`, `APP_ENCRYPTION_KEY`, `OPERATOR_TOKEN`
    - Feature switches: `SPONSORSHIP_ENABLED`, `SPONSOR_*`, `CIRCLES_ENABLED`
    - Email and push: `RESEND_API_KEY`, `EMAIL_FROM`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY`, `APNS_TOPIC`
    - `SENTRY_DSN`
  - **Web**, `artifacts/moolahub-app/.env.example`: `VITE_PRIVY_APP_ID`, `VITE_PRIVY_CLIENT_ID`.
  - **iOS**, `apps/ios/Config/Env.example.xcconfig`: `PRIVY_APP_ID`, `PRIVY_APP_CLIENT_ID`, `API_BASE_URL`, `PASSKEY_RP_ORIGIN` (a full `https://` origin, because that is what Privy's Swift call takes [P16]: `https://app.moolahub.io` in Prod, `https://staging.moolahub.io` in Dev and Staging, F5), `OAUTH_URL_SCHEME`.
- **iOS config files are gitignored**, to follow your rule, even though every value in them is public.
  - A bootstrap script writes them from the example on laptops and in CI (GitHub Actions and Xcode Cloud, IOS:41).
  - `project.yml` gains Dev, Staging and Prod configurations with `configFiles` (today: Debug and Release, and one bundle ID, `project.yml:31-37,57`).
  - A build step fails if a config holds any key outside the allowlist.
- **Secret scanning:**
  - gitleaks in CI on every push and PR, plus one full-history scan. This is the control that enforces. A branch push scans everything on the branch that is not on the default branch, so a cancelled run loses nothing; the full-history scan also reads pull request refs and merge commits.
  - A pre-commit hook in `.githooks/`, switched on by `scripts/setup.sh` running `git config core.hooksPath .githooks` (unset today). The setting is repository-wide: it covers every worktree.
  - Custom rules for Privy's documented secret prefixes, `privy_app_secret_…` and `wallet-auth:…` [P68], and for what gitleaks' built-in rules miss here: a bare 64-hex key, a password in a URL, an RPC URL's key, a P-256 key body (an unprefixed Privy authorization key, an APNs key), a Resend key and this project's own secret names. The fallback scanner has the same rules.
  - A build check that fails if `apps/ios/**`, `WEB/**` or the built `dist/public` contains a server secret name or a `-----BEGIN` header. CI also builds the web app with a canary value in every server secret name and fails if one reaches `dist/public`.
  - GitHub secret scanning and push protection: both on for the repository (checked 2026-10-29 with the GitHub API; V19). Non-provider patterns and validity checks are off. Turning on non-provider patterns, which catch generic keys and connection strings, is a founder setting worth changing.
- **No server secret ever gets a `VITE_` name** (`WEB/components/app/Web3Provider.tsx:7` compiles one into the bundle).
- **If a secret leaks:** rotate it first, investigate second.

---

## 3. Architecture

### 3.1 Invariants (each has a test in §6)
1. **No path to user money.**
   - The API never receives a Privy access or identity token.
   - It never holds an owner or signer key for a user wallet.
   - It never calls `/v1/wallets/authenticate` [P6].
   - Privy tokens in requests are refused with 400 in **every** environment and never logged.
2. **Ledger first, scoped.**
   - **Money mutations** never call Privy or the chain inside a request (SPEC:183-184). Workers do that.
   - **The only request paths that call Privy:**
     - `POST /auth/session`: `getByWalletAddress` [P11].
     - `POST /auth/identities/sync`: re-read the user.
     - `POST /auth/step-up/verify`: re-read the user for high-risk scopes.
   - On those paths, every Privy call has a 3-second timeout and answers 503 `try_again` with `Retry-After`, never 500.
   - **No request path calls the chain.** Signatures are checked offline (§3.4). Deletion reads the indexer's snapshot (§3.7). `refresh` and `/me` touch only our database.
3. **One-to-one mapping.** One Privy DID = one Moolahub user = one embedded wallet on 8453.
4. **Sponsored requests only.** Only server-prepared, device-signed, allowlisted requests are sponsored, within meters that also reserve a budget for withdrawals.
5. **No secrets leak** into git, the iOS binary, the web bundle, logs (pino) or Sentry.
6. **Minimal personal data.** Every user-keyed table has a declared deletion action (§3.7).
7. **MFA before money and security changes** (F8, decided). Without `mfa_ready_at`, the server refuses every action in F8's list that reaches it with 403 `mfa_missing`: every money move, sponsorship, wallet export through our screens, adding or removing a sign-in method (F8's two exceptions aside), email change, lock and unlock. The check runs on the server for every request, never only in the app. The server cannot refuse what never reaches it: a key export on Privy's own page or the exit page (A21), or a link made at Privy (§3.5). Whether export works before MFA is V34 (F8 follow-up).

### 3.2 Schema (new databases only; generated SQL in `lib/db/migrations/0004_privy_identity.sql`)
**Migration guard.** `scripts/post-merge.sh:8-9` migrates any environment where `MIGRATIONS_DATABASE_URL` is set. P1 merges only after both:
- the F7 export is done;
- the old Replit environment is confirmed to have no `MIGRATIONS_DATABASE_URL`.

**`users`** (adapts `DB/users.ts:6-61`)

| Column | Rule |
|---|---|
| `id` | uuid PK (internal key everywhere; unchanged) |
| `privy_did` | NOT NULL UNIQUE (nullable today, :11). **Kept on the tombstone** as a pseudonymous ID, so late webhooks can be matched and ignored |
| `name` | **Nullable** until the profile is complete (NOT NULL today, :9) |
| `username` | Nullable; unique on `lower()` (keep :60) |
| `email` | Nullable (NOT NULL UNIQUE today, :10); unique `lower(email) WHERE email IS NOT NULL AND deleted_at IS NULL` |
| `email_source`, `email_is_private_relay` | `email\|google\|apple`; whether it is an Apple relay address |
| `date_of_birth` | Keep; used for the 18+ check |
| `residence_country` | Self-attested (decision 23, SPEC:39). **`nationality` (:27) is dropped** unless counsel needs it |
| `terms_version`, `terms_accepted_at`, `age_confirmed_at` | v1.0 gate (SPEC:796); nothing exists today |
| `profile_completed_at`, `mfa_ready_at` | `profile_completed_at` gates the `full` session. `mfa_ready_at` gates the actions in F8's list (invariant 7); it is set when MFA is first seen and cleared when MFA disappears (§3.5) |
| `security_hold_until`, `security_hold_reason` | §3.5 |
| `locked_at`, `lock_reason`, `unlock_requested_at` | F14; replaces `deactivated_at` (:33) |
| `sessions_not_before` | Sign out everywhere |
| `deleted_at`, `privy_deleted_at` | §3.7 |
| Kept as is | `avatar_url`, `referral_source`, `timezone`, `language`, `notification_preference`, `notification_prefs`, streak and vacation fields, `created_at`, `updated_at` |
| **Dropped** | `password_hash` (:17), `email_verified_at` (:19; Privy verifies), `deactivated_at`, `two_factor_*` (:36-38) |

**Other tables**
- **`user_identities`** (a mirror of Privy's linked accounts):
  - Columns: `id`, `user_id`, `type` (`email|google_oauth|apple_oauth|passkey|wallet|totp`), `subject`, `email`, `is_private_relay`, `mfa_enrolled`, `origin` (`moolahub_flow|detected`), `first_seen_at`, `last_seen_at`, `removed_at`.
  - Indexes: **unique `(type, subject) WHERE removed_at IS NULL`**, and an index on `lower(email) WHERE removed_at IS NULL`.
  - Field sources are the user object [P12]. Google gives subject, email and name; Apple gives subject and email. There is no verified flag, so these emails are treated as asserted by the provider.
- **`devices`:** `id`, `user_id`, `platform`, `label`, `se_public_key` (iOS Secure Enclave, IOS:40), `app_attest_key_id`, `attested_at`, `push_token`, `push_env`, `created_at`, `last_seen_at`, `revoked_at`.
- **`sessions`** (replaces `DB/sessions.ts`, where the token is stored in plain text at :9):
  - Columns: `id`, `user_id`, `device_id`, `family_id`, `scope` (`onboarding|full`), `access_hash`, `access_expires_at`, `refresh_hash` (unique), `refresh_expires_at`, `absolute_expires_at`, `rotated_from`, `successor_id`, `rotated_at`, `proof_type`, `created_at`, `last_used_at`, `revoked_at`, `revoke_reason`, `step_up_at`, `step_up_scope`, `step_up_params_hash`.
  - Hashes are SHA-256 of 32 random bytes.
- **`auth_challenges`:** `id`, `purpose` (`signin|stepup|stray_delete`), `nonce_hash` (unique), `user_id`, `device_id`, `origin`, `chain_id`, `expires_at` (5 minutes), `used_at`.
- **`wallets`** (adapts `DB/wallets.ts`):
  - Keep `user_id` unique and `address` unique.
  - Add `chain_id`, `privy_wallet_id` (unique), `owner_verified_at`, `signers_checked_at`, `delegate_address`, `delegate_seen_at`, `deleted_at`.
  - Drop `private_key_enc`, `custody`, `network`, the CHECK and `funded_at`.
- **New support tables:**
  - `security_events` (append-only, allowlisted fields).
  - `privy_outbox`: rows of `delete_user|freeze_user|unfreeze_user|delete_stray`, each with a **stored user proof** and retries.
  - `sponsorship_usage`.
  - `push_outbox`.
  - The spec's `idempotency_keys`, `goal_movements`, `earn_positions`, `webhook_inbox` (SPEC:178-179).
- **Tables dropped:** `email-verification`, `password-reset`, `reauth`, `twofactor`, `passkeys`, and `onchain_transfers` (`DB/onchain.ts:20-32`, where a null source means the platform key).

### 3.3 Sign-in methods per platform

| Method | iOS (Privy Swift ≥ 2.17, iOS 17+ [P33]) | Web (React SDK, after F10) |
|---|---|---|
| Apple | `privy.oAuth.login(with: .apple)`; the client ID is the bundle ID [P14] | OAuth redirect using the Services ID (may wait for the App Store, V23) |
| Google | `privy.oAuth.login(with: .google, appUrlScheme:)` [P13] | `useLoginWithOAuth().initOAuth({provider, disableSignup})` [P13]. It may fail in in-app browsers such as WhatsApp [P3], so detect that and offer "Open in browser" or the email code |
| Passkey | `privy.passkey.signup(relyingParty:displayName:)` / `.login(relyingParty:)`; `relyingParty` is a full origin [P16]; needs the AASA file and the `webcredentials:` entitlement | `useSignupWithPasskey` / `useLoginWithPasskey` [P16] (web RP ID and cross-platform use: V9) |
| Email code | `privy.email.sendCode(to:)` then `loginWithCode(_:sentTo:)` [P2] | `useLoginWithEmail` (unconfirmed; V18) |
| MFA | Custom screens; Privy's ready-made MFA screens are React-only [P20]. Swift has transaction MFA since 2.9.0 [P58] (listener API: V26) | Privy MFA hooks |

All sign-in screens are our own; there is no Privy modal anywhere (SPEC:745). The length of the email code is not hard-coded, because it is undocumented [P2].

### 3.4 Sessions and API authentication

**Challenge**
`POST /api/auth/challenge {purpose, deviceId, sePublicKeyHash}` returns `{nonce, message, expiresAt}`. The message is a fixed template, and the iOS verifier allows only this template and the step-up template (SPEC:129):
```
Moolahub sign-in · purpose:signin · nonce:<128-bit> · device:<id> · sekey:<sha256(SE pubkey) | web> · origin:<APP_ORIGIN host> · chain:8453 · issued:<ISO>
```

**`POST /api/auth/session {proof, device}`. Checks, in order:**
1. Consume the nonce atomically: `UPDATE … SET used_at=now() WHERE used_at IS NULL AND expires_at>now() RETURNING`. The origin and chain must match this environment.
2. Rebuild the message on the server. The device ID and key hash must equal the ones submitted.
3. **Check the signature offline: 65-byte ECDSA only.** Use viem's `verifyMessage` *utility*, which supports only plain wallets (EOAs) and makes no RPC call [P75]. Formats for contract wallets (ERC-1271, 6492, 8010) are refused, so no 7702 delegate code decides who signs in. If Privy returns any other format, that is an S0 finding (V7).
4. Call `getByWalletAddress` [P11] (an allowed Privy call, §3.1). The wallet must be the user's embedded Ethereum wallet with `userCanSign` true [P12]. Take the DID, the linked accounts and the MFA state (V28 has the field names).
5. **Scope.** If the profile is complete, issue a `full` session; otherwise `onboarding`. MFA no longer decides the scope (F8, decided 2026-10-29). An onboarding session may only:
   - read `/me`;
   - edit the profile and check whether a username is free;
   - link an email, if the account has none;
   - set up MFA (offered, not required);
   - sync identities;
   - log out.

   A `full` session without `mfa_ready_at` can do everything except the actions in F8's list, which answer 403 `mfa_missing` (invariant 7). `/me` returns the MFA state, so the app can start MFA setup before the person taps.
6. **New DID:** apply the duplicate rules (§3.5), then create the user, identities, wallet (`privy_wallet_id` from the wallet's `id`, V5), device and session.
   **Existing DID:** the address must equal the stored wallet. Otherwise return 409 `wallet_mismatch` and record a security event.
7. Diff Privy's linked accounts against `user_identities` (§3.5).
8. Refuse if `locked_at` or `deleted_at` is set.
9. iOS: App Attest is checked here and on refresh (IOS:40). It is monitored at first, enforced later.

**Tokens**
- **Web:** a `__Host-mh_session` cookie (HttpOnly, Secure, SameSite=Lax, Path=/). This works because web and API share one host (F6).
- **iOS:** returned in the JSON body (`X-Client: ios`, `API/lib/auth.ts:96-114`) and kept in the Keychain as described in F2.

**Middleware** (rewrite of `API/lib/auth.ts:6-25`)
- Read the cookie only for web and `x-session-token` only for iOS, never both. Today either is accepted from any client (:7).
- Look sessions up by hash.
- Refuse the request if:
  - the session is revoked or expired;
  - the device is revoked;
  - the user is locked or deleted (today only deletion is checked, :22);
  - the session is older than `sessions_not_before`;
  - the session's scope is too low for the route;
  - the route is in F8's list and the user has no `mfa_ready_at`, read from the database on each request (403 `mfa_missing`).
- A cookie-authenticated mutation must carry an allowed Origin. Today a missing Origin is let through (`API/lib/origins.ts:44-50`).

**Privy tokens.** `Authorization: Bearer`, `privy-token` and `privy-id-token` are refused with 400 in every environment and never logged. The operator console uses `x-operator-token` (`API/lib/auth.ts:49`), so nothing else breaks.

**Web Privy cookies stay off: a deliberate departure from Privy's checklist.** Privy's checklist recommends HttpOnly cookies [P68]. We leave Privy's base-domain cookies and identity tokens off, because they would send Privy tokens to our domain [P7, P9] and break invariant 1. The web Privy session therefore sits in browser storage [P9]. The F10 controls (CSP, policy, MFA) are the compensation.

**Refresh** (`POST /auth/refresh`)
- Every refresh rotates the token. On iOS it must also carry a Secure Enclave signature over a fresh nonce, so a stolen token alone is useless.
- **Grace window.** If the same parent token comes back from the same device within 10 seconds, return the same successor. The iOS client refreshes one request at a time.
- **Reuse.** Reuse outside that window revokes the whole family, records a security event and notifies the user.
- **When our refresh expires:**
  - If it **expired normally** and the Privy session is alive, the app repeats the sign-in proof. Once MFA is set up, that shows a passkey prompt unless MFA was passed in the last 15 minutes [P22]. Without MFA there is no prompt (F8).
  - If the **server revoked it** (`revoke_reason` set), the app shows the full sign-in screen and needs a Secure Enclave signature.

### 3.5 Account linking, duplicates and detected changes
**Privy's list of linked accounts is the truth.**
- Linking, email changes and unlinking happen at Privy through the client SDK, before our server hears of them. Privy documents no MFA requirement for linking [P23]. That linking needs a signed-in Privy session is our inference from P23.
- So our step-up cannot *prevent* a link made outside our screens. We **detect** it instead.

**Detection**
- **When:** Privy's list is compared with ours at every `/auth/session`, every `/auth/identities/sync`, every high-risk step-up, by an hourly job, and in the relay worker before each money move.
- **Webhooks**, where available (dev free; prod needs Enterprise [P50]): `user.linked_account`, `user.unlinked_account`, `user.updated_account`, `mfa.disabled`.
- **On any change that did not come through our own screens:**
  - a security event;
  - a notice by push and to every known email;
  - an **account-wide hold** (default 72 hours): no new cash-out destination, no email change, no deletion, and no MFA change through our screens.
- **On MFA removed, or an extra wallet signer appearing:** clear `mfa_ready_at`, block money and every other action in F8's list, notify.
- **On MFA set up for the first time, or again after removal** (seen through our screens or detected here): set `mfa_ready_at` and apply F8's first-setup rules. Every other session is revoked and notices go out. If the device is not the one that created the account, the account-wide hold also starts and money moves wait out its 72 hours.

**Our own linking screen**
- Settings → "Sign-in methods" uses `privy.oAuth.link`, `privy.passkey.link`, `privy.email.linkWithCode` [P23], then `/auth/identities/sync` with step-up.
- Adding or removing a method here needs MFA set up first (F8, decided). The exceptions are the passkey that MFA setup itself links, and the first email on an account that has none.
- A user has at most one email [P23].
- Unlinking the last method, or the only MFA method, is refused.

**Duplicate rules**
- **R1.** One DID per user.
- **R2.** One active user per non-relay email, checked across `users.email` **and** active `user_identities.email`.
- **R3.** If a new DID brings an email another user holds, no account is created. The server returns 409 `account_exists` with the existing method types. Then the stray cleanup in F9 runs:
  1. The stray wallet signs a `purpose:stray_delete` challenge.
  2. The worker checks USDC = 0, shares = 0 and nonce = 0, and that the DID has no Moolahub user.
  3. The outbox calls Privy delete [P28].
  4. The app tells the person how to sign in and link.
- **R4.** Apple relay addresses (`privaterelay.appleid.com`) never match another email.
- **R5.** "Disable sign-up" on sign-in-only screens is web-only: React has `disableSignup` [P13], Swift documents none.
- **R6.** Privy account transfer stays off.

### 3.6 Step-up (separate from Privy MFA)
**Template.** It binds the action:
```
Moolahub step-up · scope:<scope> · params:<sha256(canonical params)> · session:<id> · nonce · origin · chain · issued
```

**Proof**
- **iOS:** a Secure Enclave signature over the template, which needs Face ID (IOS:40, IOS:55). High-risk scopes also need a wallet signature over the same template, which passes through Privy MFA once MFA is set up. High-risk scopes are: new destination, unlink, email change, delete, unlock.
- **With F8 decided:** new destination, unlink, email change and unlock also need MFA set up first, so their wallet signature always passes through Privy MFA. Delete does not need MFA (F8), so before MFA its wallet signature proves only the Privy session.
- **Web:** the wallet signature.
- Never an email code alone (today's fallback, `API/lib/stepUp.ts:82-92`, is removed).

**The grant** lasts 5 minutes. It is single-use for cash out, destination and delete, and valid only for the exact `params` hash.

**Which step-up gates exist after the change** (today's uses come from `grep verifyStepUp API/routes`)

| Today | After |
|---|---|
| Change password (`auth.ts:521`), 2FA (`security.ts:61,103`), Moolahub passkeys (`passkeys.ts:126`), Privy link (`auth.ts:657`) | Removed with those features |
| Server withdraw (`wallet.ts:91`) | Removed (custody). Cash out, if shipped (SPEC:17), keeps step-up plus a 24-hour hold on new destinations (SPEC:149) |
| Referral withdrawal (`referral.ts:50`) | Removed (decision 22, SPEC:38) |
| Goal release (`goals.ts:155`), goal delete (`goals.ts:193`) | Plain release or delete of an **unlocked cash goal** is a ledger move between the user's own accounts, so no step-up. **Breaking a lock** needs step-up (SPEC:149). Any of these that moves money needs MFA set up (F8) |
| Deactivate (`account.ts:64`) | Lock needs no step-up (it is defensive, F14). Unlock follows F14. Both exist only once MFA is set up (F8) |
| Delete account (`account.ts:99`) | Kept (high-risk). Does not need MFA set up (F8) |
| — | New: link or unlink a method through our screens, email change. Both need MFA set up first (F8) |

### 3.7 Logout, sign out everywhere, lock, deletion
- **Sign out on this device:**
  - Revoke the session family.
  - The client calls Privy logout, which deletes the saved Privy session [P26], and wipes the Keychain and caches.
- **Sign out everywhere** (includes this device):
  - Revoke all sessions and set `sessions_not_before`.
  - The outbox calls Privy **freeze, then unfreeze**, because Privy documents no other way to end sessions through its API: freeze revokes all sessions [P27], and revoking without freezing exists only in the dashboard [P27]. Whether this pair is reliable is V24.
  - Every device then needs the interactive sign-in.
- **Lock / unlock:** see F14. Both exist only once MFA is set up (F8). Lock revokes our sessions, and the outbox freezes the Privy user [P27]. Unlock goes through the emailed link, 72 hours, then unfreeze. Wallets are unchanged by freeze [P27].
- **Outbox safety.** Each `delete_user`, `freeze_user`, `unfreeze_user` and `delete_stray` row carries a stored user proof: a device or wallet signature, or a single-use email-link token, kept as a hash. The worker re-verifies that proof against the registered key or token **before** calling Privy, and alerts on every such call. Writing a row into the database alone can never trigger a Privy action.
- **Delete account** (in-app, as Apple requires [P31]; it does not need MFA set up, F8):
  1. Step-up.
  2. Show balances: the ledger, **including** `referral:` (excluded today, `API/lib/ledger.ts:174-209`), plus the indexer's on-chain snapshot.
     - If at least $0.01, require an explicit acknowledgment and offer key export (A21, [P44]) or cash out if it exists.
     - **Never block deletion on balance alone.** Dust anyone sends would otherwise block it.
  3. **Tombstone now**, following the inventory below.
  4. **Privy delete is deferred.** The outbox calls `users().delete` [P28] only when the worker re-reads zero USDC, zero shares and a zero ledger balance at that moment. Privy deletion archives the wallet and recovery is not guaranteed [P28]. If money remains, the Privy user stays, the exit page (A21) keeps working without a Moolahub session, and the user is told.
  5. Apple: token revocation and the server-to-server notification endpoint [P31, P72] go to V13.
  6. A full erasure at Privy is requested by email to Privy's privacy team [P62].

**Deletion inventory** (a test fails if any new user-keyed table has no row here)

| Data | Action |
|---|---|
| `users` | Tombstone: name "Deleted member"; email, username, birth date, avatar URL and residence cleared; `privy_did` kept (pseudonymous); `deleted_at` set |
| `user_identities`, `devices`, `sessions`, `auth_challenges` | Delete |
| `wallets` | Keep the row with `deleted_at` (the address is needed to reconcile the ledger) |
| Ledger accounts and postings | Keep (RESTRICT; SPEC:6) |
| Goals | Keep amounts; replace names with "Goal" |
| `circle_invites` for the user's emails (`DB/circles.ts:48`) | Delete |
| Avatar object | Delete. Claimed objects are never swept today (`API/lib/objectStorage.ts:362-364`); today's deletion only clears the column (`API/routes/account.ts:113-132`) |
| `notifications` | Delete |
| `security_events` | Keep N months with allowlisted fields only (N set with counsel, SPEC-B6) |

### 3.8 Wallet creation and the security snapshot
- **Creation.** The client creates the wallet right after Privy sign-in:
  - iOS: `user.createEthereumWallet(allowAdditional: false)`;
  - web: `useCreateWallet`.

  The SDKs never make a second wallet by default [P35]. React's automatic creation doesn't run with our own sign-in screens [P36].
- **Snapshot.** The server stores a **security snapshot**: linked accounts, MFA state, and the wallet's `additional_signers` and `policy_ids`, read from `GET /v1/wallets/{id}` [P71].
  - Owner check: require `additional_signers` to be empty and the expected policies. `owner_id` is a key-quorum ID, not a DID [P71], so mapping it to "this user" is V6; until then the user object's `userCanSign` [P12] stands in.
  - The snapshot is refreshed at session creation, by the hourly job, and by the relay worker before each money move.
- **Chain.** Every iOS request sets `chainId 0x2105`, because Swift defaults to Ethereum mainnet [P54]. Server requests use `eip155:8453`.

### 3.9 Gas-sponsored transactions on Base
- **Who builds.** The server prepares the exact Privy request:
  - an Earn deposit or withdraw on the pinned vault, with a `reference_id` [P49]; or
  - a USDC transfer, if cash out ships. The transfer **wallet action** takes `reference_id` [P49]; whether it is sponsored is V21.

  Each request has an idempotency key and an expiry of at most 1 hour (SPEC:122). Prepare makes no Privy call (SPEC:183).
- **Who signs.** After the device verifier (SPEC:114-130) and the prompt from F12, the device runs `user.generateAuthorizationSignature(payload:)` [P43]. Privy signs the transaction inside its TEE.
- **Who sends.** The worker relays through **raw REST**, with the app secret, the `privy-authorization-signature` header [P43] and `privy-idempotency-key` [P49].
  - It does not use the Node SDK's `authorization_context`, which the CI ban list keeps forbidden (SPEC:146; [P76]).
  - Swift cannot request sponsorship itself; only React and server SDKs can [P38]. Relaying through our server is the only path for iOS.
  - Earn actions are sponsored by default [P49].
- **Recovery after a lost response:**
  - Earn and transfer actions: `GET /v1/actions?reference_id=` [P49].
  - `/rpc` `eth_sendTransaction`: `GET /v1/transactions?reference_id=` [P70].
  - **`wallet_sendCalls` has no documented `reference_id`** [P70]. The v1.1 circle batch recovers through the idempotency key plus the stored `transaction_id` (V21).
- **Who pays.** Moolahub, through prepaid gas credits (gas plus a fee) [P39], with EIP-7702 and a paymaster [P39]. How the first 7702 upgrade happens for a Swift-relayed request is V3: Swift documents no 7702 signing [P57].
- **Limits, built to resist many fake accounts:**
  - **Allowlist at launch:** `earn_deposit` and `earn_withdraw` on `PRIVY_VAULT_ID`, only if the Earn gate passes. A USDC transfer is allowed only to a destination past its 24-hour hold, and only if cash out ships. v1.1 adds circle `approve(exact)+contribute`.
  - **Eligibility:** a complete profile, MFA enrolled, and either a confirmed on-ramp deposit or an account at least 24 hours old (configuration).
  - **Minimum sponsored amount:** $1 by default.
  - **Meters:** per user, per device, per IP prefix (/24 for IPv4, /48 for IPv6), per wallet, and app-wide per day. Privy has no per-user cap of its own [P40].
  - **A separate reserved exit budget** for `earn_withdraw` and cash out. Deposits can never use it up, so people can always take money out.
  - **Over a cap,** the movement stays `queued` with a message. It never silently falls back to user-paid gas. Key export stays available as the user's own exit [P44].
  - A velocity alert on sponsored actions from new accounts.
  - A kill switch, `SPONSORSHIP_ENABLED=false`.
- **Credit monitoring** (corrected; there is no balance API):
  - Turn on Privy's low-credit notices; the auto-refill decision is in F11 [P63].
  - The worker sums `gas_credits_charged` from each settled transaction [P42] into `sponsorship_usage`.
  - Every `insufficient_funds` error from the relay raises an alert [P64].
  - `GET /v1/apps/gas_spend` (1–100 wallets, at most 30 days, totals only [P41]) is used only to reconcile per-user meters.
- **Asynchronous results.** Responses carry `transaction_id` and `user_operation_hash`, and `hash` stays empty until confirmation [P42]. The ledger is therefore keyed on Privy's transaction or action ID.

### 3.10 Ledger
Unchanged from v1 and SPEC §3:
- Keep the double-entry ledger and the append-only postings.
- Add `transit:<u>` and the spec's accounts.
- Requests write intent and return 202.
- Settle only on a re-fetched action with non-null `share_amount`, at Base's `safe` head.
- For wallet balances the chain is the truth, reconciled by the indexer (SPEC:6; A13).

### 3.11 Background jobs (a separate worker on a Reserved VM with row leases, SPEC:667; today's settlement loop assumes one instance, `API/lib/settlement.ts:935-948`)

| Job | Cadence | Does |
|---|---|---|
| relay | 5 s | Re-checks the security snapshot and meters, then sends one signed Privy request; retries the identical request |
| action-poller | 15 s, backing off | Settles by ID or `reference_id` |
| indexer | per block | Base USDC and vault-share movements (A13); balance snapshots for deletion |
| autosave | hourly | Cash: ledger. Earn: "tap to save" push (SPEC:212) |
| push-outbox | 10 s | APNs sends, written in the same database transaction (IOS:53) |
| privy-outbox | 1 min | Freeze, unfreeze, delete, stray-delete, each after re-verifying the stored proof and on-chain state |
| security-diff | hourly | Compares Privy linked accounts, MFA and signers with ours (§3.5) |
| webhook-inbox | on insert / 1 min | Deduplicated events |
| gas-credit-monitor | 5 min | Spend totals, relay errors, meters |
| streaks | existing (`API/index.ts:45`) | Kept |
| referral accrual | existing (`API/index.ts:46`) | **Retired** (decision 22, SPEC:38) |
| session-reaper | daily | Purges expired sessions and challenges |
| orphan-review | daily | Report of stray Privy users not yet cleaned |

### 3.12 Webhooks
- **Mount at `/api/webhooks/privy`, not `/webhooks/privy`.** On Replit only `/api` reaches Express (`artifacts/api-server/.replit-artifact/artifact.toml`: `paths = ["/api"]`). Everything else is rewritten to the web app's `index.html` (the web `artifact.toml`), which would answer Privy's calls with a 200 and silently lose every event.
- **Registration order.** Register it with `express.raw({limit: "256kb"})` **before** `express.json` (`API/app.ts:55`) and before the limiters (`API/app.ts:84-85`).
- **Handling:**
  - Verify with `webhooks().verify` and `PRIVY_WEBHOOK_SECRET` [P50].
  - Store in an inbox unique on `svix-id`.
  - Handlers re-fetch before crediting anything.
- **Events used:**
  - `user.deleted`: lock the user, and page support if the balance is above zero [P25].
  - `user.linked_account`, `user.unlinked_account`, `user.updated_account`, `mfa.disabled`: §3.5.
  - `wallet_action.earn_*`, `transaction.confirmed`: nudge the poller.
  - `usage.gas_sponsorship.recorded`: meters.
- **Staging smoke test:** send a signed test event and check it lands in the inbox table.

### 3.13 Rate limits
- **Today:** a per-IP limit of 20 requests per 15 minutes covers all of `/api/auth` (`API/app.ts:78-84`), and the app re-checks `/auth/me` on every launch (`API/app.ts:59-61`). With 15-minute access keys, people sharing one carrier IP would be logged out (IOS:56 N8).
- **New:**
  - `/auth/refresh` and `/auth/me` leave the per-IP auth limiter. They are limited per refresh family and per device.
  - `/auth/challenge` and `/auth/session`: per IP with a higher ceiling (60 per 15 minutes), plus 20 per hour per address or DID.
  - Step-up: 5 failures per 15 minutes per user, then a 15-minute lock.
  - `prepare`: 30 per minute per user.
  - `identities/sync`: 5 per hour per user.
- The in-memory throttles (`API/lib/loginThrottle.ts`) move to the database.
- **Outgoing Privy calls:** a token bucket, plus exponential backoff with jitter on 429. Privy publishes no numbers [P51].

### 3.14 Observability
- **Sentry.** It already drops headers and bodies by allowlist (`API/lib/sentryScrub.ts:228-233`) and masks JWT-shaped strings (:41). Add `privy-id-token`, `privy-token`, `privy-authorization-signature`, `signature`, `refreshToken` and challenge messages.
- **pino.** Today it redacts only `authorization`, `cookie` and `set-cookie` (`API/lib/logger.ts:7-11`), and errors are logged whole (`API/app.ts:114`).
  - Add redact paths `err.config`, `err.request`, `err.headers`, `*.authorization` and `*["privy-authorization-signature"]`, plus a custom error serializer.
  - A test logs a Privy-shaped error carrying an Authorization header and asserts that nothing leaks.
  - Built in P0, widened by the P0 review: every log line, not only pino-http's, cuts a `req` or `res` down to the request line; compound key names (`emailCode`, `authorizationKey`, `x-api-key`), child logger fields, class instances and `%o`/`%j` arguments are scrubbed; secret query parameters and any 64-hex value inside a string are masked, transaction hashes included.
- **Metrics:**
  - sign-ins by method and failure (`nonce_expired`, `bad_signature`, `non_ecdsa_signature`, `owner_mismatch`, `account_exists`);
  - `mfa_missing` refusals by route, and first MFA setups, split by whether the device created the account (F8);
  - refresh reuse;
  - detected identity changes;
  - step-up failures;
  - relay latency and action states;
  - sponsored spend;
  - relay `insufficient_funds`;
  - Privy 429s;
  - outbox calls by type.
- **Alerts:**
  - refresh-reuse spike;
  - spend over 80% of the daily cap;
  - `insufficient_funds`;
  - any `owner_mismatch` or unexpected signer;
  - any Privy delete, freeze or unlink call;
  - `settlement.dead_letter` (SPEC:720).

### 3.15 Sequences

**Sign up (iOS, Apple)** (MFA timing per F8, decided 2026-10-29)
1. `privy.oAuth.login(with: .apple)` [P14], then `user.createEthereumWallet(allowAdditional:false)` [P35].
2. `POST /auth/challenge`. The wallet signs with `wallet.provider.request(.personalSign(message:address:))` [P73]. No MFA exists yet, so there is no prompt.
3. `POST /auth/session` runs the §3.4 checks. The profile is not complete, so it answers 201 with an `onboarding` session.
4. **Profile:** name, username (with `GET /auth/username-available`, which is kept from `API/routes/auth.ts:477`), birth date and 18+ confirmation, residence, terms. Then `PATCH /api/profile`.
   - Passkey-only sign-ups also link an email (`privy.email.linkWithCode` [P23]). That they have no email otherwise is our inference. This is F8's first-email exception, so it needs no MFA.
5. The server marks the profile complete and upgrades the session to `full`.
6. **MFA offer:** "Set up a passkey now", or later. If accepted, it runs as in "Setting up MFA" below. If not, the account works except for F8's list, and the app keeps reminding.

**Setting up MFA** (at sign-up if accepted, otherwise at the first action in F8's list)
1. If the server answered 403 `mfa_missing`, or `/me` shows no MFA, the app explains why and starts setup.
2. `privy.passkey.link`, then `user.mfa.passkeys.enroll.submit(credentialIds:)` [P20]. If passkeys are unavailable, the authenticator-app flow. A passkey sign-up skips the link, because its passkey is already a sign-in method (our inference from [P20]).
3. `POST /auth/identities/sync` with step-up. The server re-reads the Privy user, sees MFA, sets `mfa_ready_at`, records a security event, and applies F8's first-setup rules: every other session revoked, notices sent, and the hold if this is not the device that created the account.
4. The app goes back to the action it was on. Whether setup counts as a passed MFA, so the next signature needs no prompt within 15 minutes, is V32.

**Sign in on a new phone (email code)**
1. `sendCode`, then `loginWithCode` [P2].
2. Challenge, then signature. If MFA is set up, Privy asks for the passkey, because this is signing on a new device [P21]. If not, there is no prompt: this is the gap accepted in F8 (V33).
3. `/auth/session`: the existing DID, the matching address, a `full` session. A `signin_new_device` event and a notice to the user. Without MFA, that session cannot do anything in F8's list.

**Returning on the same phone**
1. `GET /auth/me` returns 401.
2. `POST /auth/refresh` with the Secure Enclave signature; the token rotates.
3. If the refresh expired normally, repeat the proof. Once MFA is set up, that shows a passkey prompt if more than 15 minutes have passed since MFA [P22]. If the server revoked the session, show the sign-in screen.

**First sponsored Earn deposit** (staging on 8453 with the $100 throwaway wrapper, SPEC:788)
1. `POST /api/v1/goals/:id/deposits/prepare` with `Idempotency-Key`. Without `mfa_ready_at` the server answers 403 `mfa_missing` and the app runs "Setting up MFA" first (F8). The server locks the goal, checks caps and meters, creates the movement in `awaiting_signature` with `reference_id = movementId`, and returns the exact request with an expiry of at most 1 hour. There is no Privy call.
2. The device verifier checks it, the F12 prompt runs, then `generateAuthorizationSignature` [P43].
3. `POST …/confirm {signature}`: post `wallet→transit`, state `queued`, answer 202.
4. **Relay worker:**
   - re-checks the snapshot (MFA, signers) and meters, and refuses on drift;
   - posts with `privy-idempotency-key`;
   - recovers by `reference_id` if the response is lost [P49];
   - past the expiry, sets `expired` and posts `transit→wallet`.
5. **Poller:** at the `safe` head with non-null `share_amount`, post `transit→goal` and record `gas_credits_charged` [P42].
6. iOS polls `GET /v1/transactions/:id` until Done.

A cash-goal deposit, by contrast, is one ledger posting and costs no gas (SPEC:192).

---

## 4. What changes in the code

**Order.** Interface work (web, iOS screens) comes after P9. The exceptions are the web "upgrading sign-in" holding screen (F7) and the iOS device-verifier module, which has no UI.

**Contract first (P1).** Every API change starts in `lib/api-spec/openapi.yaml`, then codegen (`pnpm --filter @workspace/api-spec run codegen`):
- `UserProfile.email` becomes nullable (`lib/api-zod/src/generated/types/userProfile.ts:12`).
- The new auth paths replace `/auth/privy` (:243), `/auth/register` (:287) and `/auth/login` (:318).
- The web pages that import the old generated hooks (`WEB/components/auth/AuthForm.tsx`, `SignUpForm.tsx`, `TwoFactorStep.tsx`, `WEB/components/app/ChangePasswordCard.tsx`) are replaced by the F7 holding screen in P2, so the root typecheck stays at 0 errors.

**Backend: keep**
- `API/app.ts` proxy, helmet and CORS.
- `API/lib/origins.ts`, with "cookie requires Origin" added.
- `API/lib/ledger.ts` and the append-only postings.
- `requireOperator` (`API/lib/auth.ts:43-63`).
- `API/lib/crypto.ts` with `APP_ENCRYPTION_KEY` (upload tokens).
- Streaks, notifications, learn, profile, storage and activity.
- `API/lib/email.ts`, for product and security email only.

**Backend: adapt**

| Path | Change |
|---|---|
| `API/lib/auth.ts:6-25,65-120` | Hashed lookup, client split, scopes, lock checks, refresh |
| `DB/users.ts`, `DB/sessions.ts`, `DB/wallets.ts` | §3.2 |
| `API/lib/privy.ts` | Rewrite on `@privy-io/node`, pinned exactly and at least 14 days old (SPEC:714): `getByWalletAddress`, `_get`, `delete`, freeze/unfreeze, webhook verify, wallet get. Today it uses `@privy-io/server-auth` (`package.json:41`), which is deprecated [P10] |
| `API/routes/auth.ts` | Becomes challenge, session, refresh, logout, logout-all, me, identities/sync; **keep `username-available` (:477)**, rate-limited |
| `API/lib/stepUp.ts` | §3.6 |
| `API/routes/account.ts:56-136` | Lock and unlock (F14); split deletion (§3.7) |
| `API/routes/wallet.ts` | Read only. Remove `/wallet/deposit` (:54), `/wallet/withdraw` (:83), `/wallet/withdraw/submitted` (:114), `ensure-gas` (:141), `sync` (:171) |
| `API/lib/settlement.ts` | Relay of device-signed requests. Remove user-key and platform-key sends (`resolveSourceKey`, :217-223) |
| `API/index.ts:44-46` | Jobs move to the worker; referral accrual is retired |
| `API/app.ts:55,78-85` | Webhook route before the JSON parser; limiter changes (§3.13) |
| `API/lib/circles.ts:931,958,1090`; `API/routes/circles.ts:54,280,299`; `API/routes/profile.ts:20` | Handle a null email. `API/lib/notifications.ts:80-82` already tolerates one |
| `API/lib/logger.ts` | §3.14 |
| `API/routes/index.ts:27` | Circles mount only when `CIRCLES_ENABLED=true`. Otherwise every `/circles*` route returns 404 and `/onchain/config` drops circle fields (P0). Today nothing checks the flag: a search of `artifacts`, `apps` and `lib` finds it nowhere. **As built in P0 (P0 review, default (founder may change)):** with the flag off, every circle route that starts something answers 404, and `/onchain/config` drops the circle addresses and the platform address. Reads stay open, so members still see existing circles, and so does confirming a contribution the member's own device already sent on chain, so money that moved reaches the ledger. The settlement loop and the indexer still finish circle transfers already queued; a new database has none. `scripts/dev-ios-backend.sh` does not set the flag, so the frozen demo's group screens get 404 on changes |

**Backend: delete (P2)**
- **Old auth:**
  - routes `API/routes/auth.ts:160-551` (except `username-available`), :555-629, :633-703, :707-749;
  - `API/routes/security.ts`, `API/routes/passkeys.ts`;
  - helpers `password.ts`, `loginThrottle.ts`, `resetThrottle.ts`, `emailVerification.ts`, `passwordReset.ts`, `reauth.ts`, `twofactor.ts`.
- **Custody and Monad:**
  - `API/lib/wallet.ts:23-45,170-186`;
  - `API/lib/chain.ts` (platform key, `ENABLE_PRIVY_CUSTODY`, `generateAccount`);
  - `circleChain.ts`, the Monad indexer, `gasTopupThrottle.ts`;
  - faucet and server withdraw in `deposits.ts`;
  - `API/routes/onchain.ts:23` (platform address).
- **Server-key goal and referral paths** (SPEC:215-217):
  - `/goals/:id/allocate` (`API/routes/goals.ts:114`), `/release` (:141), `/deposit/submitted` (:219), `/release/submitted` (:256);
  - `requireServerCustody` (`API/lib/goals.ts:204,413`);
  - the referral payout with a null source (`API/lib/referrals.ts:761-786`);
  - the `onchain_transfers` table;
  - `artifacts/api-server/scripts/set-fee-sink.mjs` (signs with the platform key, :19-22).
- **Platform-address circle flows** (`API/lib/circles.ts:388,566`) stay behind the circles flag until v1.1 replaces them.
- **Config:** the whole Monad block in `.replit:92-107` (and the same names in every deployment's Replit Secrets), plus the root `.env.example` private-key names. Never add `PRIVY_AUTHORIZATION_KEY` or `KEEPER_PRIVATE_KEY`. P0 already removed the block from `.replit` except `ENABLE_PRIVY_CUSTODY = "true"`, which stays until this deletion: without it, "Continue with Privy" falls back to a server-held key (P0 review).
- **Tests:**
  - delete `twofactor*` and `password-reset*` e2e tests;
  - rewrite `auth-http`, `stepup-http`, `native-session-http`, `account-delete-http`;
  - move `circles-http`, `circles-http-authz`, `circles-invite-authz`, `home-data-http` and `profile-timezone-http` (which create users through password auth) onto a test-only session fixture, so `db-ci` `test:offline` (`.github/workflows/db-ci.yml:96-100`; `package.json:36`) stays green.
- **Dev tooling:**
  - `artifacts/api-server/scripts/seed-ios-dev.ts` imports password, wallet-key and faucet code (:130-133, :206, :238), so it is rewritten.
  - `scripts/dev-ios-backend.sh` loads `.dev/api.env` and then unsets the Privy variables (:69, :86-90), binds to 0.0.0.0 (:94) and logs email codes (:96). It stays only for the frozen demo. A new `scripts/dev-privy-backend.sh` binds to localhost, logs no codes and reads `.dev/privy-dev.env`.

**Backend: new**
- `API/lib/base.ts`, `API/lib/identity.ts` (the proof interface; only the wallet proof is implemented), `API/lib/sessions.ts`, `API/routes/session.ts`.
- `API/lib/securitySnapshot.ts`, `API/lib/sponsorMeter.ts`, `API/lib/privyRelay.ts` (raw REST), `API/routes/webhooks.ts`, `API/lib/securityEvents.ts`, `API/lib/push.ts`.
- The jobs in §3.11, and a role-address manifest checked at boot.

**CI ban list** (over `artifacts/api-server/**` and `lib/**`, scripts included):
- Forbidden names: `user_jwts|authorization_context|authorizationContext|authorization_private_keys|verifyAuthToken|verifyAccessToken|wallets/authenticate|getTestAccessToken|addSigners|privateKeyToAccount`.
- Any import from `viem/accounts`.
- Any `process.env.*PRIVATE_KEY` **or** `process.env["…PRIVATE_KEY"]`; bracket access is used in this code base (`API/index.ts:13,30`).
- This extends SPEC:146. The new SDK's `verifyAccessToken` [P9] would slip past the old list.
- Built in P0 as `scripts/check-api-ban-list.mjs`, run by the secret-scan workflow. Today's testnet files may keep their current number of uses until P2 deletes them, so a new use anywhere fails at once.

**Boot checks on 8453**
- Refuse to start if any legacy Monad name is set. Built in P0 (`API/lib/legacyChainEnv.ts`): with `CHAIN_ID` 8453 or 84532 the API refuses to start while a Monad testnet or server-custody name is set. Today's testnet API sets no `CHAIN_ID`.
- Every role address used must match a checked-in, human-confirmed manifest (replit.md:37; CLAUDE.md non-negotiable). Still open: P0 built only a format check (`API/lib/roleAddresses.ts`), which passes when no role is set and cannot tell whether a person confirmed an address. The deploy gate today is `contracts/script/VerifyBase.s.sol`, which compares the roles with the deployment manifest and refuses an empty `DEPLOY_EOAS`.
- USDC is a code constant (ARCH:1502), asserted at boot.

**iOS (after the backend, except the verifier module)**
- **Privy package.** `Package.swift` adds `privy-ios` at an exact version in an isolated Auth/Wallet target. It is a closed binary [P33].
- **Project setup.** `project.yml` gets Dev, Staging and Prod configurations, `configFiles`, three bundle IDs, and an entitlements file: Sign in with Apple, `webcredentials:app.moolahub.io` in Prod and `webcredentials:staging.moolahub.io` in Dev and Staging (F5, decided), push, URL scheme. None exists today (`apps/ios/README.md:184-185`).
- **Device verifier** (A19): a Swift module with no UI and its tampered-request corpus, built in P4.
- **Screens (UI phase):**
  - Welcome / sign-in methods, the email code, the profile step, MFA setup and verify, plus a listener for Privy MFA requests (V26).
  - The MFA offer at the end of sign-up, the reminder, and MFA setup started by a 403 `mfa_missing` before the first money move (F8).
  - Settings → Sign-in methods, Lock my account, Sign out everywhere, the new step-up.
  - The duplicate-account and stray-cleanup flow.
  - Delete `ForgotPasswordView` and `TwoFactorView`.
- **Session and DTO changes:**
  - `KIT/Auth/SessionStore.swift`, `KIT/Persistence/TokenStore.swift:60`: Keychain classes as in F2.
  - `KIT/Domain/DTO/AuthDTOs.swift:27`, `AccountDTOs.swift:10`: `email` becomes optional.

**Web (after the backend)**
- `WEB/components/app/Web3Provider.tsx`: Base chains; remove `SmartWalletsProvider` and `monadTestnet` (:3-4); `showWalletUIs:false`; explicit wallet creation; no Privy base-domain cookies.
- Auth components replaced. Wallet-setup and money components deleted.
- **CSP:** response headers through Replit [P78; V27], inline scripts moved out of `index.html`.
- **Pin `@privy-io/react-auth`** exactly, at ≥ 3.33.1 and at least 14 days old. Today it is `^3.28.0` (`package.json:83`).

---

## 5. Security and threat model

| Threat | Controls | Proof |
|---|---|---|
| **Forged or redirected sign-in proof** | Single-use 5-minute nonce bound to purpose, device ID, Secure Enclave key hash, origin and chain; message rebuilt on the server; offline ECDSA check only; owner lookup [P11]; App Attest monitored then enforced (IOS:40) | Unit tests: wrong signer, reused or expired nonce, wrong origin or device, ERC-1271/6492 format refused, address owned by another DID |
| **Replay** | Nonces; rotation with a 10-second grace window and reuse detection; Secure Enclave signature on refresh; `Idempotency-Key`; `privy-idempotency-key`; `svix-id` inbox | e2e: same key with a different body returns 409; a double tap moves money once; parallel refresh does not log out |
| **Server obtains wallet power** | No Privy tokens accepted (all environments); no `/wallets/authenticate`; no signers or owner keys [P45, P69]; snapshot drift blocks money; ban list | CI grep; snapshot test with a planted signer |
| **Account change outside our screens** (Privy-side link, email change, MFA off) | Our step-up cannot stop it [P23]. **Detection**: diffs, hourly job, webhooks; account-wide hold; notices on every channel (§3.5) | e2e with the fake Privy directory: a planted link triggers hold and notice |
| **Inbox or SIM theft, after MFA is set up** | No SMS. **Once MFA is set up**, new-device signing needs it [P21], so no session either. Email change needs MFA set up, step-up, and notifies the old address. Before MFA, see the next row | Staging: once MFA is set up, an email-code sign-in on a new device cannot get a session without the passkey |
| **Inbox-only access before MFA is set up** (F8, 2026-10-29) | **Accepted by the founder** (verbatim): "someone with only your inbox could open the account and see your details until a passkey exists". **Found after the answer, pending the founder (F8 follow-up):** the person can also edit the profile, delete the account, and use sign out everywhere again and again; they can set up MFA first and hold an account our screens put no money in (recovery is V16); Ghana users may never close the gap; and, if V34 confirms it, they can export the wallet key on Privy's page, which our server cannot refuse, and that key still works after MFA, so money added later could be taken (options in F8). **Mitigations:** sign-up offers MFA and the app reminds; our screens put no money in, and nothing is sponsored, without MFA (§3.9); the server enforces F8's list for every action that reaches it (invariant 7); every new-device sign-in sends a notice; first MFA setup signs out every other device and notifies; setup on a device other than the one that created the account starts the 72-hour hold with a lock link; lock and unlock exist only with MFA, so the inbox alone cannot lock an owner out for good | e2e: without MFA, every route in F8's list answers 403 `mfa_missing` and `prepare` refuses; S0: V34 answered with captured evidence; first MFA setup revokes other sessions and sends notices; setup from a second device starts the hold. Staging: an email-code sign-in on a new device before MFA gets a session that cannot move money |
| **Lost passkey** | Authenticator-app backup [P21]; nudge to add a second method; key export (A21, [P44]). Recovery when every method is lost is undocumented (V16) | Recovery drill on staging |
| **Web XSS** | A loaded Privy wallet can sign anything, read-only screens or not (SPEC:45). Controls: strict CSP header, no inline or third-party scripts, user-owned policy before any web wallet (V8), MFA on signing once set up (before that our screens put no money in, F8; a key exported before MFA is V34), Privy cookies off by design (§3.4) | CSP test; pentest (SPEC-B5) |
| **Gas drain by many fake accounts** | Client sponsorship off [P38]; allowlist; eligibility; minimum amount; per-user, device, IP-prefix, wallet and app meters; reserved exit budget; velocity alerts; kill switch; `insufficient_funds` alert [P64] | Load test: N fake accounts exhaust the deposit budget, and withdrawals still run |
| **Webhook spoofing or loss** | Svix signature on the raw body at `/api/webhooks/privy`; inbox dedup; re-fetch before credit [P50] | Tampered body refused; staging smoke test |
| **Privy app secret leak** (corrected from SPEC:600) | With the secret alone, someone can **delete users** (wallets archived, recovery not guaranteed [P28]), **unlink methods** [P74] and **freeze** [P27]. It cannot sign. Controls: full secret only on the worker; API uses a read-only secret (V25); outbox actions need stored user proofs; alerts on every delete, unlink or freeze; rotate on suspicion | Secret scan in CI; outbox test: a row without a valid proof is refused |
| **Admin path to principal** | User is sole owner; no Moolahub signer; no server keys after P2; support cannot lock, unlock or delete (F14); role manifest checked at boot | "No code can sign for a user" test (P2) |
| **Privacy** | Only DID, method type and subject, email (relay respected), name, username, birth date (18+), residence, timezone, language. No OAuth tokens; Swift cannot read them anyway [P13]. pino and Sentry scrubbed. Deletion inventory | Scrub test (SPEC:711); personal-data allowlist test |

---

## 6. Build plan, backend first

**S0 runs in weeks 1–2, in parallel with P0.** It needs only the Privy dev app and the staging host (SPEC:739; IOS:70). Merge gates:
- P1's wallet-signature proof merges only after V5–V7 are answered.
- P4's relay merges only after V2 and V3 are answered.

| Phase | Scope | Done when |
|---|---|---|
| **P0 Baseline and safety** | F0 steps (done 2026-10-29); `.gitignore`; examples; root `.env.example` rewrite; gitleaks (CI + hook + Privy prefixes); hooks setup script; ban list; pino and Sentry redaction; **circles flag enforced**; Monad block removed from `.replit` (except `ENABLE_PRIVY_CUSTODY`, kept until P2, §4); role manifest boot check; document amendments (§0) | A planted fake key is blocked locally and in CI; `git check-ignore -v` matches a sample of each pattern; a planted `verifyAccessToken` and `process.env["X_PRIVATE_KEY"]` fail CI; a circle route returns 404 with the flag off; boot fails with a legacy Monad var set. **Status after the P0 review (2026-10-29):** met locally: planted fakes blocked by the fallback scanner, ignore patterns, the ban list on planted names, the circle 404s, the boot refusal on a Base `CHAIN_ID`. **Still open:** every "in CI" check, until `secret-scan.yml` has run once on a throwaway branch with planted fakes (gitleaks had not run on this config before the push); the role manifest check (only a format check exists, §4) |
| **S0 Privy spike** | Answer every Privy [VERIFY] (§7) with captured evidence | Written go/no-go. A no-go on V2/V3 re-plans money moves |
| **P1 Identity and sessions** (fakes: local keys, a fake Privy directory and HTTP server) | Migration 0004; OpenAPI + codegen; `identity.ts`; endpoints; scopes; middleware; the F8 MFA gate (invariant 7); R1–R4; auth limits; test session fixture; config and market fields (A10) | Root `pnpm run typecheck` = 0; `db-ci` `test:offline` green; `test:auth` covers sign-up without MFA, onboarding vs full scope decided by the profile alone, every route in F8's list answering 403 `mfa_missing` without `mfa_ready_at` (a test for invariant 7), the first-email exception, `account_exists`, `wallet_mismatch`, rotation, grace window, reuse revokes the family, logout-all, locked user, cookie without Origin → 403, header path, cookie and header never mixed; a DB-constraint test for invariant 3 |
| **P2 Retire legacy auth and custody** | §4 deletions; web holding screen; frozen demo tag (F7); new seed and dev launcher; referral currency retired (A18) | A search finds no `private_key_enc`, `getSigningSecret`, `PLATFORM_PRIVATE_KEY`, `monadTestnet`, `password_hash`, `verifyAuthToken`, `onchain_transfers` in `artifacts/api-server/**` or `lib/**`; a test asserts that nothing imports `viem/accounts` |
| **P3 Step-up, lock, deletion, detection** | §3.5–3.7; F8's first-setup rules; outbox with stored proofs; security snapshot and diff job; App Attest monitoring | e2e: deletion is never blocked by dust, and Privy delete runs only at zero; deletion works without MFA; outbox refuses a row without a proof; step-up single-use, 5 minutes, bound to its parameters; a planted link causes hold and notice; first MFA setup revokes every other session and records the event; MFA set up from a device other than the one that created the account starts the hold and blocks money moves for 72 hours; MFA removed clears `mfa_ready_at` and blocks F8's list; lock and unlock refused without MFA; a personal-data allowlist test for invariant 6 |
| **P4 Money rails on fakes + indexer** | Idempotency (A3), `goal_movements`, prepare/confirm, relay (raw REST), poller, meters with exit budget, webhook inbox at `/api/webhooks/privy`, worker with leases (A8, A9-mock), indexer (A13), `/v1` and `transactions/:id` (A16), **iOS device verifier module + corpus** (A19) | Property tests prove SPEC §3.5; network loss mid-confirm leaves one Processing row and one ledger entry; a duplicate webhook is a no-op; a tampered-request corpus is all refused |
| **P5 Push and email** | Devices' push tokens, APNs, push outbox, security notices by push and email (A16, IOS:53) | A notice reaches a test device; no amounts in push text (IOS:27) |
| **P6 Real Privy on dev (Base Sepolia)** | Plain test sign-in screens **on real iPhones** (passkeys and Apple need real devices; passkey domain `staging.moolahub.io`, F5); all four methods; MFA set up before the first money move (F8); a sponsored USDC self-transfer relayed from the device; webhooks (free in dev [P50]); gas monitor | Each method yields a session; logs never contain a Privy token; the transfer is refused with 403 `mfa_missing` before MFA, then settles after MFA setup; `gas_credits_charged` recorded; on a second iPhone, an email-code sign-in before MFA gets a session that cannot move money, and after MFA it gets no session without the passkey; V32, V33 and V34 answered with captured evidence |
| **P7 Add money backend** (A14) | Hosted provider session (IOS:19 D7, N13). Starts only when an on-ramp contract exists (SPEC-B7) | A $10 on-ramp posts once (SPEC:753) |
| **P8 Staging on Base 8453** | Needs the §2 #30 prerequisites (key ceremony about 2 weeks; SPEC:775). $1 Earn deposit and withdraw; lock and unlock; real Privy delete of a test user; stray cleanup | `reference_id` recovery works (SPEC:748); deletion strands nothing |
| **P9 Hardening** | Rate-limit load test with N users behind one IP; alert-firing tests; runbooks; pentest prep (SPEC-B5); production Privy app with Apple custom credentials **before** Apple is turned on; App Review account (F13) | Limits and alerts fire in tests; production checklist signed by two people |
| **UI-1 Design gate** | Full screen list (below), flows, error and empty states, copy in all six locales (`WEB/i18n/locales/{ar,en,fr,ha,pcm,sw}`) under the copy guard (SPEC:84) | Founder design review signed off |
| **UI-2 iOS sign-in and account** | Welcome, methods, email code, profile, the MFA offer at the end of sign-up and its reminder, MFA setup before the first money move (F8), MFA verify, Sign-in methods, Lock (shown only with MFA), Sign out everywhere, delete, duplicate and stray flow, errors (`account_exists`, `wallet_mismatch`, locked, MFA missing, hold, including the 72-hour hold after MFA set up on another device) | Snapshot tests light and dark with Dynamic Type XL; `performAccessibilityAudit` passes (IOS:41); usability test of sign-up, and of the first money move with MFA setup, with 5 people |
| **UI-3 iOS money** | Goals, Add money, Earn moves with the F12 prompt pattern, Activity with Processing, exit page (A21) | Network cut mid-confirm leaves one Processing row; a real $10 round trip (IOS:73, minus the dropped 2% fee, SPEC:22, and cash out unless an off-ramp is contracted, SPEC:17) |
| **UI-4 Web** | Per F10 | CSP test; same flows on web |

**SPEC §9 mapping**

| SPEC item | Where |
|---|---|
| A1 money-safety fixes | Check what commit 5f2ca56 already did [VERIFY]; the rest in P1 |
| A2 database platform | P0/P1 (Supabase, SPEC-B1) |
| A3 idempotency and hashed sessions | P1 + P4 |
| A4 retire custody | P2 |
| A5 Sentry | Done in 54da0cf; extended in P0 |
| A6 invisible-crypto UX | UI-1 to UI-4 |
| A7 Base config and SDK | P4 (server) + UI-4 (web) |
| A8 goals on mock Earn | P4 |
| A9 Earn client, poller, inbox | P4 (mock), P8 (real) |
| A10 market eligibility, `/v1/config` | P1 (decision 23 is yours) |
| A11 circles | v1.1 |
| A12 auth hardening | P1/P2 (Moolahub passkey and TOTP items become moot) |
| A13 indexer | P4 |
| A14 Add money | P7 |
| A15 Cash out | P7 only if an off-ramp is contracted, otherwise cut (SPEC:17) |
| A16 push, `/v1`, transactions | P4 + P5 |
| A17 deletion | P3 |
| A18 referral rewards off | P2 |
| A19 device verifier | P4 module + UI-3 |
| A20 CI gate | P0 |
| A21 exit page | P8 + UI-3 |

**What each credential unlocks**

| Credential | Unlocks |
|---|---|
| F0 go-ahead (given 2026-10-29) | P0 |
| Domain, DNS, staging deployment, AASA | Passkeys (S0, P6) |
| Privy dev app + Base Sepolia RPC + test USDC | S0, P6 |
| Apple organization account, App IDs, Services ID, SIWA key | Apple sign-in (dev, then staging and prod) |
| Google client + domain verification | Google sign-in with our credentials (dev can start on Privy's defaults [P3]) |
| APNs key, Resend key and DNS | P5 |
| On-ramp contract (SPEC-B7) | P7 |
| Privy staging app + credits, Supabase staging, Earn prerequisites, real USDC | P8 |
| Privy prod app with plan and Apple custom credentials; Supabase prod; Sentry; App Store Connect record | P9, launch |

---

## 7. Risks and open [VERIFY] items

**Risks**
1. **Plan conflict.** Until P0 amends the documents, ARCH and BP tell engineers to send Privy tokens to the server (ARCH:396) and to keep keeper keys in env (BP:28). Amended in P0 on 2026-10-29, with dated notes on the remaining stale lines. Closed with the P0 commits.
2. **Apple credentials trap.** Turning on Apple with Privy's default credentials cannot be undone [P3].
3. **Passkey domain is permanent** (F5): `app.moolahub.io`, decided 2026-10-29. Passkeys will never work on another `moolahub.io` host.
4. **Lost MFA** with no backup locks the user out of their money. Recovery is undocumented (V16).
5. **Gas credits run out.** Money stalls in Processing: safe, but it looks bad. Privy rejects with `insufficient_funds` [P64].
6. **Google sign-in** may fail in WhatsApp's in-app browser [P3]. Google's consent screen may show a domain, not "Moolahub" (V22).
7. **Single vendor.** Key export and the exit page (A21) are the user's way out.
8. **Funding.** Privy's Stripe flow covers the US (excluding New York) and the EU only [P60]. GH, NG, KE and ZA need another provider (SPEC-B7).
9. **App Store.**
   - Offering Google requires an equivalent privacy-preserving login [P30, 4.8]; Sign in with Apple is the usual fit.
   - In-app deletion is required [P31].
   - Finance apps should come from a company account [P30, 5.1.1(ix)].
10. **Signature billing.** Pay-as-you-go starts at 50,000 signatures a month [P52]. Each sign-in, step-up and money move adds signatures (F11).
11. **Android users** depend on the web (F10). Web Apple sign-in may wait for the App Store (V23).
12. **A leaked app secret** can delete, unlink and freeze users (§5).
13. **Privy-side changes are detected, not prevented** (§3.5).
14. **Inbox-only access before MFA** (F8, 2026-10-29). Accepted by the founder: someone with only the inbox can open an account that has no MFA and see its details. Pending the founder (F8 follow-up): they can also edit or delete the account and sign everyone out again and again; they can set up MFA first and hold the account (recovery V16); Ghana users may never set up MFA, so for them the gap lasts; and, if V34 confirms it, they can copy the wallet key, which keeps working after MFA, so money added later could be taken.
15. **Public repository** (F0). `Moolahubio/app` is public, so anything pushed is visible to everyone. Secret scanning (§2) runs on every push, and GitHub push protection is on (V19).

**Open [VERIFY] items** (resolved in S0 unless noted)

| ID | Item | How to check | Blocks |
|---|---|---|---|
| V1 | Is an identity token refused at `/v1/wallets/authenticate`, which takes a generic user JWT [P6]? | Written answer + staging call | Any use of identity tokens |
| V2 | Swift `generateAuthorizationSignature` + server relay with sponsorship on `/rpc` and Earn [P43] | End-to-end on dev and staging | All money moves |
| V3 | How the 7702 upgrade happens for a Swift-relayed request; the delegate address (SPEC:81, SPEC:129; [P57]) | Privy answer; inspect the first sponsored transaction | iOS sponsorship |
| V4 | Are new apps TEE by default [P37]? | Dashboard | Sponsorship |
| V5 | Is the wallet `id` non-null for TEE embedded wallets (null when not delegated, per [P12])? | Dev app | Relay, snapshot |
| V6 | Map `owner_id` (a key-quorum ID [P71]) to the user | Privy | Owner check |
| V7 | Is `personal_sign` from a 7702-upgraded embedded wallet a plain 65-byte ECDSA signature ([P73] does not say)? | Dev app | Sign-in (F3), step-up |
| V8 | Can user-owned policies bind the owner's own requests and express SPEC:132-139 [P47]? | Privy | F10, defence in depth |
| V9 | With F5 decided: is the web passkey RP ID `app.moolahub.io` in prod and `staging.moolahub.io` in dev and staging; does one passkey work across web and iOS; is the exact `relyingParty` value `https://app.moolahub.io` (an origin [P16])? | Dev app on `staging.moolahub.io`, then prod before launch | Passkeys on iOS and web, F10 |
| V10 | Allowed range of the dashboard MFA window (`mfa-cache-duration` [P21]); identity-token lifetime differs between pages [P7, P8] | Dashboard | F12 |
| V11 | Exact error when linking a method owned by another Privy user with transfer off [P24]; duplicate behaviour across email, Google and Apple [P61] | Dev app | F9 |
| V12 | Do test accounts work on production apps, and can they enrol an authenticator app [P29]? | Privy | F13 |
| V13 | Does Privy revoke Apple tokens on deletion, and does it receive Apple's server-to-server notifications [P31, P72]? If not, we register an endpoint | Privy | App Store |
| V14 | Plan tier for the policy engine and key quorums ("add-on" [P52]); Enterprise price; convenience fee; how device approval signatures count toward billing; login-email customisation outside Enterprise [P2] | Privy sales (SPEC-B3) | F11 |
| V15 | Numeric rate limits [P51] | Privy | Meters |
| V16 | Wallet recovery when every method is lost (that unfreeze keeps the wallet is closed by [P27]) | Privy | F14, recovery |
| V17 | Swift OAuth browser mechanism ([P13] silent) | Dev app | Google on iOS |
| V18 | React email hook name; can React sign behind the verifier (SPEC:151)? | Dev app | F10 |
| V19 | Replit and GitHub secret visibility by role; gitleaks CLI syntax. **GitHub push protection: resolved 2026-10-29.** Secret scanning and push protection are on for `Moolahubio/app` (GitHub API); non-provider patterns and validity checks are off, and turning on non-provider patterns is a founder setting worth changing | Replit and GitHub docs | §2 |
| V20 | Ownerless Privy wallet for the keeper (F4) | Privy | v1.1 |
| V21 | `reference_id` on `wallet_sendCalls` ([P70] lists only `eth_sendTransaction`); are transfer wallet actions sponsored? | Privy | v1.1 circles; cash out |
| V22 | Can Google brand verification pass with the redirect on `auth.privy.io` [P65, P66]? Is there a custom auth domain? | Privy + Google | Google branding |
| V23 | Does Apple enforce "an existing App Store app" for web Services IDs [P72]? | Apple | Web Apple sign-in |
| V24 | Does freeze-then-unfreeze reliably end every Privy session? Is there an API to revoke sessions without freezing ([P27]: dashboard only)? | Dev app | Sign out everywhere |
| V25 | How to create a read-only app secret ([P68] advises one; [P64] lists a permissions error), and does it allow `getByWalletAddress`? | Privy | Secret split |
| V26 | Swift MFA-required listener and headless MFA; can the app know in advance that Privy will prompt (SPEC:142)? | Dev app | F12 |
| V27 | Response headers and rewrites in Replit `artifact.toml` (the docs show `.replit` syntax [P78]); is `/.well-known/apple-app-site-association` served as JSON from `publicDir` with no rewrite? | Replit + staging check; CI fetch check asserts 200, JSON, no redirect, expected app IDs | F5, F10 |
| V28 | Node SDK field names for MFA state (passkey MFA enrolment is shown in the user object [P12]; `mfaMethods` placement unclear) | Dev app | F8 |
| V29 | Thresholds of Privy's low-credit notices [P63] | Dashboard | Gas monitor |
| V30 | Privy dashboard branding fields | Dashboard | §2 #12 |
| V31 | Does Privy's code email reach Apple relay addresses (Privy's sender would need registering in our relay settings [P72])? | Privy + Apple | Apple users signing in by email code |
| V32 | Does setting up MFA count as passing it, so a signature within the next 15 minutes needs no prompt [P22]? | Dev app | F8 first money move, F12 |
| V33 | With no MFA set up, can a new device sign with the wallet after only an email-code sign-in (the gap F8 accepts; our reading of [P21])? Is a first MFA setup visible in the user object straight away (V28)? | Dev app | F8, §5 |
| V34 | With no MFA set up, can a Privy session export the wallet key (Privy's export screen [P44], or the Privy API with the user's token), or sign typed data or a 7702 authorization? Is there a Privy setting or a user policy that requires MFA before export, and can it be lifted once MFA exists? (P0 review; [P21] says MFA guards export only once set up) | Dev app: an email-code account with no MFA tries each; Privy's written answer | F8 follow-up, P1 merge, §5 |

---

## Appendix A. Review history

The design was fact-checked against the sources in Appendix B and reviewed for security, correctness and completeness on 2026-10-29, and v2 includes the resulting fixes. The P0 build was reviewed the same day for security, correctness and documentation; the changes that review made to this design are marked "P0 review" (header, §0, F0, F8 and its follow-up, invariant 7, §2, §3.14, §4, §5, §6, §7 and V34).

## Appendix B. Sources

All pages were read on 2026-10-29; those marked * were read again for v2, and P21 and P44 again for the P0 review (the export facts in F8).

**Privy: sign-in and tokens**

| ID | Page |
|---|---|
| P1* | https://docs.privy.io/security/authentication/user-authentication |
| P2* | https://docs.privy.io/authentication/user-authentication/login-methods/email |
| P3* | https://docs.privy.io/basics/get-started/dashboard/configure-login-methods |
| P4 | https://docs.privy.io/authentication/user-authentication/jwt-based-auth/overview (+ /setup, /usage) |
| P5 | https://docs.privy.io/controls/authorization-keys/keys/create/user/overview |
| P6 | https://docs.privy.io/api-reference/wallets/authenticate |
| P7* | https://docs.privy.io/user-management/users/identity-tokens |
| P8 | https://docs.privy.io/authentication/user-authentication/tokens |
| P9* | https://docs.privy.io/authentication/user-authentication/access-tokens |
| P10 | https://docs.privy.io/basics/nodeJS-server-auth/setup |
| P11 | https://docs.privy.io/user-management/users/managing-users/querying-users |
| P12* | https://docs.privy.io/user-management/users/the-user-object |
| P13* | https://docs.privy.io/authentication/user-authentication/login-methods/oauth |
| P14 | https://docs.privy.io/recipes/swift/apple |
| P15 | https://docs.privy.io/basics/get-started/dashboard/app-clients |
| P16* | https://docs.privy.io/authentication/user-authentication/login-methods/passkey |

**Apple: passkeys and Sign in with Apple**

| ID | Page |
|---|---|
| P17 | https://developer.apple.com/documentation/authenticationservices/supporting-passkeys |
| P18* | https://developer.apple.com/documentation/xcode/supporting-associated-domains (read via https://developer.apple.com/tutorials/data/documentation/xcode/supporting-associated-domains.json) |
| P19 | https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.applesignin |

**Privy: MFA and user management**

| ID | Page |
|---|---|
| P20* | https://docs.privy.io/authentication/user-authentication/mfa/setup (also /mfa/enrollment/passkeys) |
| P21* | https://docs.privy.io/authentication/user-authentication/mfa/overview |
| P22* | https://docs.privy.io/authentication/user-authentication/mfa/verify/overview |
| P23* | https://docs.privy.io/user-management/users/linking-accounts |
| P24* | https://docs.privy.io/recipes/mobile-account-transfer |
| P25 | https://docs.privy.io/api-reference/webhooks/user/deleted |
| P26 | https://docs.privy.io/authentication/user-authentication/logout |
| P27* | https://docs.privy.io/user-management/users/managing-users/freezing-users |
| P28* | https://docs.privy.io/user-management/users/managing-users/deleting-users |
| P29* | https://docs.privy.io/recipes/using-test-accounts |

**Apple: App Store**

| ID | Page |
|---|---|
| P30* | https://developer.apple.com/app-store/review/guidelines/ |
| P31* | https://developer.apple.com/support/offering-account-deletion-in-your-app/ |

**Privy: SDKs, wallets and gas**

| ID | Page |
|---|---|
| P32 | https://docs.privy.io/user-management/migrating-users-to-privy/create-or-import-a-user |
| P33 | https://docs.privy.io/basics/swift/installation and https://github.com/privy-io/privy-ios/releases |
| P34 | https://docs.privy.io/basics/swift/setup |
| P35 | https://docs.privy.io/wallets/wallets/create/create-a-wallet |
| P36 | https://docs.privy.io/basics/react/advanced/automatic-wallet-creation |
| P37 | https://docs.privy.io/recipes/tee-wallet-migration-guide |
| P38* | https://docs.privy.io/wallets/gas-and-asset-management/gas/setup |
| P39 | https://docs.privy.io/wallets/gas-and-asset-management/gas/overview |
| P40 | https://docs.privy.io/wallets/gas-and-asset-management/gas/security and https://docs.privy.io/recipes/gas-sponsorship-rate-limits |
| P41* | https://docs.privy.io/wallets/gas-and-asset-management/gas/gas-spend |
| P42* | https://docs.privy.io/wallets/gas-and-asset-management/gas/transaction-handling |

**Privy: authorization, policies, Earn and webhooks**

| ID | Page |
|---|---|
| P43* | https://docs.privy.io/controls/authorization-keys/using-owners/sign/utility-functions and https://docs.privy.io/controls/authorization-keys/owners/configuration/user/server-transactions |
| P44 | https://docs.privy.io/wallets/wallets/export |
| P45 | https://docs.privy.io/controls/authorization-keys/owners/configuration/user/server-export |
| P46 | https://docs.privy.io/controls/authorization-keys/owners/overview (no longer cited for signer permissions; see P69) |
| P47 | https://docs.privy.io/controls/policies/overview |
| P48 | https://docs.privy.io/recipes/policy-based-mfa |
| P49* | https://docs.privy.io/wallets/actions/earn/deposit, https://docs.privy.io/api-reference/wallets/earn/deposit and https://docs.privy.io/wallets/actions/reference-id |
| P50* | https://docs.privy.io/api-reference/webhooks/overview |
| P51 | https://docs.privy.io/api-reference/introduction |

**Privy: pricing, apps, transactions and funding**

| ID | Page |
|---|---|
| P52* | https://privy.io/pricing |
| P53* | https://docs.privy.io/basics/get-started/dashboard/create-new-app |
| P54 | https://docs.privy.io/wallets/using-wallets/ethereum/send-a-transaction |
| P55 | https://docs.privy.io/recipes/batch-transactions |
| P57 | https://docs.privy.io/wallets/using-wallets/ethereum/sign-7702-authorization |
| P58* | https://docs.privy.io/changelogs/swift |
| P59 | https://docs.privy.io/recipes/wallets/two-of-two-server-in-the-loop |
| P60 | https://docs.privy.io/wallets/funding/use-deposit-funds |

**Other (v1)**

| ID | Page |
|---|---|
| P61 | https://github.com/Kalebtron1/Project-Vyn/pull/136 (third-party report) |
| P62 | https://docs.privy.io/user-management/users/managing-users/supporting-your-users |

**New in v2**

| ID | Page |
|---|---|
| P63* | https://docs.privy.io/wallets/gas-and-asset-management/usage-billing/overview |
| P64* | https://docs.privy.io/basics/troubleshooting/error-handling/api-errors |
| P65* | https://support.google.com/cloud/answer/15549049 |
| P66* | https://support.google.com/cloud/answer/13464321 |
| P67* | https://docs.privy.io/recipes/react/allowed-oauth-redirects |
| P68* | https://docs.privy.io/security/implementation-guide/security-checklist |
| P69* | https://docs.privy.io/wallets/using-wallets/signers/add-signers |
| P70* | https://docs.privy.io/transaction-management/transactions/reference-id |
| P71* | https://docs.privy.io/api-reference/wallets/get |
| P72* | https://developer.apple.com/documentation/signinwithapple/configuring-your-environment-for-sign-in-with-apple (read via https://developer.apple.com/tutorials/data/documentation/signinwithapple/configuring-your-environment-for-sign-in-with-apple.json) |
| P73* | https://docs.privy.io/wallets/using-wallets/ethereum/sign-a-message |
| P74* | https://docs.privy.io/guide/server/users/unlink |
| P75* | https://viem.sh/docs/actions/public/verifyMessage |
| P76* | https://docs.privy.io/controls/authorization-context |
| P77* | https://docs.base.org/base-chain/quickstart/connecting-to-base |
| P78* | https://docs.replit.com/references/deployment-customization/static-deployments-advanced.md (found via a search that also listed https://docs.replit.com/cloud-services/deployments/static-deployments and the third-party https://unpwned.io/qa/replit/how-to-secure-replit-apps, which was not relied on) |

**Repo evidence.** Every file and line cited inline was read on 2026-10-29; `.env.example` was read for names only, and `.replit` for names plus the non-secret values cited (`:5`, `:94`, `:95`, `:112`).
