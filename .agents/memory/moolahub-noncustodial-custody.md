---
name: MoolaHub non-custodial (Privy) wallet custody
description: Dual-custody model — legacy server-custody vs new non-custodial (Privy embedded EOA) wallets; the invariant that the platform must never sign a user wallet's transfers, and the client-signed withdrawal retry rule.
---

# Non-custodial (Privy) wallet custody

MoolaHub wallets are dual-custody: legacy wallets are **server-custody** (platform
holds the key and signs) and can only be hardened, not made trustless; new wallets
can be **non-custodial** (the user's Privy embedded EOA signs on-device, platform
never holds a key). The non-custodial path ships behind a feature flag that stays
OFF until a real out-of-iframe browser + interactive Privy login + testnet E2E has
exercised it — it cannot be validated headless, so never flip it blind.

## The core invariant
For a non-custodial wallet the platform must be *structurally* incapable of signing
a transfer of the user's funds. Enforce it fail-closed at THREE independent layers,
not one: (1) the database forbids a stored key for non-custodial rows; (2) the
signing helper refuses unless the wallet is server-custody with a key present;
(3) every server-signed money path is gated to server-custody only, and the
client-confirm path is gated to non-custodial only.
**Why:** a single gate is one bug away from a custodial drain; defense in depth
means a mistake in any one layer still cannot move user funds.

## Client-signed money movement = confirm-only backend (ALL flows, not just withdraw)
Every non-custodial money-movement flow uses the same shape: the user signs
on-device, the backend only *confirms*. This covers withdrawal AND Savings-Goal
deposit/release AND Circle contribution — each has a `.../submitted` route that
takes the broadcast tx hash. The confirm verifies the on-chain receipt strictly
(tx succeeded; exactly one matching event — a typed contract event like
GoalDeposited/GoalWithdrawn/Contributed, or a token-transfer — bound to the
caller's own wallet address, the exact amount, and the goal/round id, requiring
exactly one match) and then books the ledger entry as `onchainStatus:"confirmed"`
— deliberately without a sufficient-funds precheck, because the money already left
on-chain and postings net to zero. Replay/double-count is stopped by a uniqueness
constraint on the tx hash (plus, for contributions, the per-round UNIQUE) — an
`isUniqueViolation` is caught and returned as `alreadyRecorded`. No step-up on
confirm: the on-device signature IS the authorization.
- **Server-signed and client-confirm paths are mutually exclusive**: the confirm
  fn rejects `custody!=="privy"`, and the server-signed path rejects non-server
  custody. Both gates must exist or one custody type falls through to the wrong path.
- **Reject internal destinations on withdraw-confirm** (platform, goalVault,
  factory, AND per-user escrow clones): a transfer into a vault/escrow/platform
  verifies on-chain but is NOT a withdrawal — booking it as one double-books money
  that's already booked as a deposit/contribution. Also reject a self-transfer
  (destination = the user's own wallet): moves nothing, would create a phantom entry.
- **Circle contribute routing mirrors the server path**: rotation → approve then
  `contribute()` on the circle escrow; accumulation → plain USDC `transfer` to the
  platform-custody address (exposed as `platform` in `/onchain/config`, since the
  client needs it to build the tx).

## Client retry rule (fund-safety critical)
Any client flow that broadcasts a real transfer and THEN calls a backend confirm
must never re-broadcast on retry. Persist the broadcast tx hash *before* calling
confirm; on an identical retry, re-send the confirm only.
- Clear the stored hash on a **server rejection** (the error carries an HTTP
  status — e.g. the tx reverted, so nothing left the wallet → safe to sign afresh).
- KEEP it on a **network error** (no status) so a retry only re-confirms.
**Why:** without this, a network blip between sign and confirm makes the user retry
and sign a SECOND real transfer that is never recorded.

## Gas top-up is best-effort
Any pre-sign gas top-up (funding the EOA, rate-capped per user) must be swallowed
client-side on failure/429 — the EOA may already hold gas, and the cap consumes a
slot even when funded. If gas is truly missing the sign step fails with a clear
wallet error; a top-up hiccup must not abort a withdrawal the user can already pay
for.

## Provision the embedded wallet explicitly — do NOT rely on create-on-login
The MoolaHub Privy app has embedded-wallet **create-on-login disabled** (dashboard
mode ~ user-controlled-server-wallets-only, `create_on_login: off`). So the
PrivyProvider's `embeddedWallets.ethereum.createOnLogin: "users-without-wallets"`
NEVER fires — a freshly logged-in user has NO embedded EOA, and `/auth/privy/link`
(which fails closed when no embedded wallet exists) errors "No Privy embedded wallet
found." The fix is client-side: after Privy login and before linking, call
`useCreateWallet().createWallet()` when the user has no `walletClientType==="privy"`
wallet. Because the app sets `require_user_owned_recovery_on_create=false`, creation
is silent (no UI). Swallow createWallet() errors (a wallet may already exist and the
client wallet list lags Privy) — the backend link is the source of truth.
**Why:** relying on `createOnLogin` alone is fragile and here is simply inert given
the dashboard config; explicit createWallet is Privy's recommended pattern and works
regardless of the dashboard toggle. Verified live end-to-end on Monad testnet.
**How to apply:** any client entry that must end with a linked non-custodial wallet
must ensure-then-create the embedded EOA first; the withdrawal form needs no such
step because a privy-custody DB row can only exist if the EOA already did.

## Scope boundary
Making NEW wallets non-custodial does NOT fix legacy server-custody wallets —
they stay drainable by a DB+env compromise until separately migrated or the service
is explicitly classified custodial. Treat that migration as its own phase.
