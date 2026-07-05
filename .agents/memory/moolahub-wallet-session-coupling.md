---
name: MoolaHub wallet-session ⇄ app-session coupling
description: How the Privy wallet session is tied to the app session so users connect once per login instead of at every withdrawal.
---

# Wallet session is coupled to the app session

MoolaHub keeps Privy self-custody (do NOT change custody / do NOT flip `ENABLE_PRIVY_CUSTODY`).
App auth is email/password, NOT Privy. Privy persists its own login in localStorage and is
otherwise independent from the app session. The intended model: connect the wallet ONCE per app
login, transact (withdraw/contribute/goal) freely without reconnecting, and on app logout the
Privy session also ends so the next login re-establishes both.

Two pieces implement this (app-root sync + shell banner):

- **End Privy only on a POSITIVE logged-out signal.** Fire the Privy `logout()` only when the
  `getMe` query is `isSuccess && data == null` — which is exactly what an explicit app sign-out
  produces (it sets the cached me to `null`). **Never** key off the query's error state or a bare
  `!isAuthenticated`.
  **Why:** `getMe` uses `retry:false`; a transient network failure / 5xx lands in the error state
  with `isLoading:false`, which looks identical to "logged out" via `!!user`. Tearing down a valid
  wallet session on a flaky load is the exact needless-reconnect this fix removes.
  **How to apply:** any code coupling wallet/session teardown to app auth must use the success+null
  signal, not error/loading heuristics. This also auto-covers every logout entry point (profile,
  complete-profile) without editing them, since they all set cached me to null.

- **Reconnect prompt must prefill the account email.** The one-time connect banner (and wallet
  setup) call Privy `login({ prefill: { type:"email", value: <account email> } })`.
  **Why:** logging into a DIFFERENT Privy identity yields a DIFFERENT embedded signing address than
  the linked `wallet.address`; on-chain withdrawal verification checks `from === wallet.address` and
  would fail. Prefill steers the user back to the SAME embedded wallet.

- **Gating Privy hooks:** `isWeb3Enabled` is a build-time module constant. Use the outer/inner split
  (outer calls NO hooks and returns null when `!isWeb3Enabled`; inner calls `usePrivy`/`useLogin`).
  Calling a Privy hook when `Web3Provider` rendered children without `PrivyProvider` throws.

- **No re-login loop:** this uses `usePrivy().logout()`, never `useLogin().onComplete` + a server
  exchange, so the old Privy-as-app-login re-login loop (see moolahub-auth-logout.md) does not apply.

- **Per-form connect prompts stay as fallbacks** for the edge where Privy is authenticated under a
  different identity that lacks the linked embedded wallet.

- **Testing caveat:** Privy embedded flows cannot be exercised in the preview pane / screenshot tool
  (`auth.privy.io` frame-ancestors CSP → "Privy iframe failed to load"). Verify top-level only.
