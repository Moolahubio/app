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

## Client-signed withdrawal = confirm-only backend
The user signs the transfer on-device; the backend only *confirms*. It verifies the
on-chain receipt strictly (tx succeeded; exactly one token-transfer event matching
the expected token, from = the user's wallet, to = destination, exact amount, all
address-normalized) and then books the ledger entry — deliberately without a
sufficient-funds precheck, because the money already left on-chain and postings net
to zero. Replay/double-count is stopped by a uniqueness constraint on the tx hash
scoped to withdrawals. No step-up on confirm: the on-device signature IS the
authorization. Reject a self-transfer (destination = the user's own wallet): it
verifies on-chain but moves nothing, so booking it would create a phantom entry.

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

## Scope boundary
Making NEW wallets non-custodial does NOT fix legacy server-custody wallets —
they stay drainable by a DB+env compromise until separately migrated or the service
is explicitly classified custodial. Treat that migration as its own phase.
