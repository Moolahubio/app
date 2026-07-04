---
name: MoolaHub accumulation-circle on-chain contributions
description: Design rule for accumulation Susu contribution settlement and its failure-unwind invariant
---

Accumulation circle contributions settle on-chain the same way rotation
contributions do (real member-wallet → platform-custody transfer), because
the final-round payout is real platform-funded money — a ledger-only
contribution would let a member withdraw their wallet balance AND still
collect a real payout.

**Invariant:** on the final round, the payout for every member is booked in
the SAME db transaction as the triggering (not-yet-settled) contribution. If
that contribution later dead-letters, unwinding it must, atomically:
1. reverse every member's still-owed payout ledger transaction for that
   circle/round (not just the failing contributor's — the round-completion
   precondition was never actually true), but SKIP any payout row already
   `failed` (it was already reversed by its own unrelated dead-letter path —
   reversing it again double-credits the member),
2. flip each still-owed payout's settlement-queue row to a terminal
   non-sendable state via CAS, then only reverse the ledger txn if the CAS
   won (row resolved concurrently between select and update → skip, don't
   double-reverse),
3. refuse and log loudly instead of unwinding if any payout already
   *broadcast or settled* (a `txHash` was submitted, or status/onchainStatus
   is `confirmed`) — money already moved or is irreversibly in flight.

**The reconciler batch-claim trap:** the
reconciler claims a whole batch of queue rows (flips ALL to `processing`)
*before* looping through them one at a time. So `processing` alone does NOT
mean "actively being sent" — it just means "claimed, awaiting its turn in
this pass." Treating `processing` as unsafe-to-cancel was wrong: it let a
co-claimed payout (queued right after its funding contribution in the same
batch) survive cancellation and still get sent later in the same loop using
its stale in-memory snapshot, since the loop doesn't re-check DB status per
row. Fix required BOTH sides: (a) the queue worker (`processRow`) must
re-fetch the row's live status right before sending and bail if it's no
longer `processing`, and (b) the unwind logic's CAS must accept cancelling
from `pending` OR `processing` — only a real broadcast/confirm is off-limits.

**Why:** the ledger and the settlement queue are two separate sources of
truth for "is this payout still going to happen," and a claimed-batch queue
worker is a third piece of mutable state (the in-memory snapshot) that can
go stale mid-batch. All three must agree before money moves, or a canceled
payout can still get sent, or a canceled payout can get reversed twice.

**How to apply:** any future money-movement path with this same shape
(a payout booked ahead of its funding contribution settling, processed by a
batch-claiming queue worker) must: unwind both the ledger AND the
settlement-queue row together (not just the ledger); use "broadcast/confirmed"
(not "claimed/processing") as the only unsafe-to-cancel signal; and have the
queue worker re-check live row status immediately before sending, since
batch-claimed rows are processed sequentially from a stale snapshot.
