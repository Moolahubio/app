---
name: Circle deletion (idle only)
description: When/how a circle can be hard-deleted and why it's safe
---

A circle is deletable only by its creator while `status === "forming"` and
member count <= 1 (only the creator; no accepted invites). Such a circle has
no contributions, transactions, or on-chain contract, so a **hard delete** is
safe — `circle_members`, `circle_invites`, `contributions` cascade-delete and
`transactions.circleId` is SET NULL. No money/ledger code is involved.

**Why hard (not soft like goals):** goals soft-delete because their ledger
account FK-cascades and would corrupt double-entry. A forming circle has no
such postings, so the row can be removed outright.

**Concurrency:** deleteCircle does `SELECT ... FOR UPDATE` on the circle row,
counts members, then deletes. acceptInvite's INSERT into circle_members takes a
FK row-lock on the parent circles row, which conflicts with that FOR UPDATE —
so accept and delete serialize and a circle can't be deleted out from under a
member who just joined. No explicit lock added to acceptInvite (relies on FK
lock); documented inline there.
