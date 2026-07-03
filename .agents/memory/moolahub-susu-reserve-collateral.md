---
name: MoolaHub Susu reserve/collateral mechanism
description: How MoolaHubSusuEscrow prevents an early recipient from taking the pot and defaulting; why the ledger stays untouched.
---

# Reserve/collateral fix for early-recipient default

A ROSCA/Susu pays each round's recipient the full pot immediately, but they
still owe future contributions. If they take the payout and stop paying,
honest members have no way to recover their earlier contributions once the
money has already left the contract — a genuine fund-safety hole that can't be
patched without SOME form of holdback (pure algorithm/refund-logic tweaks
can't conjure money the contract no longer has).

**Design chosen:** at settlement, withhold `contributionAmount * (roundsRemaining)`
from the recipient's own payout into `heldReserve[recipient]` (always an exact
multiple of contributionAmount). On a later round, if the caller's own reserve
covers the round's due, the escrow draws from it instead of pulling a fresh
`transferFrom` — all-or-nothing per round, no partial-credit bookkeeping. On
`cancelStalled`, a member's leftover reserve is refunded to them if they
stayed current, or forfeited and split across the round's honest contributors
if they defaulted (dust/no-honest-contributor edge cases go to treasury).

**Why not "pull full amount then refund within the same tx" instead:** that
still requires the member to have fresh liquidity on hand to submit the
transaction (it only nets to zero at the end), defeating the point. Netting
inside `_contribute()` (skip transferFrom when reserve covers it) needs no
liquidity at all.

**Off-chain ledger deliberately UNTOUCHED:** `payoutCents`/`transfer()` calls
in circles.ts keep booking the same numbers as before the fix (full amount at
settlement, full contribution debit each round) — because real spend/withdraw
gating and balance display already read on-chain balance directly
(`onchainBalances.ts`), not the ledger; the ledger is a supplementary
historical record. The ONLY off-chain change needed was teaching the
`contribute()` pre-flight wallet-balance gate to also check the escrow's
`heldReserve(address)` so a past recipient isn't blocked from a round they've
already effectively prepaid for. Trying to make the ledger numerically track
the on-chain reserve split would have required a much bigger, unnecessary
rewrite (per-round variable payout amounts, dual-booking on reserve draws).
