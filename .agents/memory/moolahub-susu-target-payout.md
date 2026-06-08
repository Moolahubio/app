---
name: MoolaHub Susu target-payout rotation
description: How target-payout rotation circles differ from legacy fixed-contribution circles (fee-on-top, fixed roster, auto-start).
---

# Target-payout rotation circles

Owner enters a TARGET payout per person + group size N (stored as `targetMembers`
on circlesTable). The rotation math:

- `base = round(target / N)`
- `contributionCents = base + round(base * FEE_BPS / 10_000)` — the 2% fee is added
  **on top** of the base, so the recipient still nets `base * N`.
- `payoutCents = base * N` (the net the recipient receives), `totalRounds = N`.

**Why fee-on-top:** the owner promises each member an exact payout (confirmed UX:
$5,000 base → $5,100/person paid in). Taking the fee out of the pot would shrink
the payout below the promised target.

## Fee unification in maybeProcessPayout
`net = circle.payoutCents ?? pot`, `fee = max(0, pot - net)`. This single formula
covers all three cases: legacy ledger circles (payout == pot → fee 0), target-payout
circles (the 2%-on-top), and legacy on-chain circles (payout stored as pot − escrow
fee). The fee row is booked even when off-chain (`onchainStatus: "none"`); only
on-chain rotation uses `"pending"`.

## Fixed roster + auto-start
A `targetMembers != null` circle locks to N people:
- `inviteToCircle` blocks invites once members + pending-invites >= targetMembers.
- `acceptInvite` activates the circle **in the same locked tx** the moment the Nth
  member joins (status active, round 1), then post-commit deploys escrow + notifies.
  It never sits stuck in "forming".
- **Manual `startCircle` is disallowed** while members < targetMembers (would shrink
  payout below target). `canStart` is always false for targeted circles — they only
  ever auto-start.

**Legacy circles untouched:** fixed-contribution rotation and accumulation keep their
original paths; everything new is gated behind `targetMembers != null` / the
`targetPayoutCents + groupSize` create branch.

## API exposure
`targetMembers` and `feeBps` are exposed on BOTH CircleSummary (list) and CircleDetail.
Remember route `.parse()` strips response fields not declared in openapi.yaml — declare
+ run `pnpm --filter @workspace/api-spec run codegen` or the client never sees them.
