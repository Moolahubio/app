---
name: MoolaHub custodial wallet hardening
description: Scoping decision for hardening a fully-custodial wallet without a non-custodial redesign; where step-up is now required
---

UPDATE: a later phase DID introduce a non-custodial (Privy embedded-EOA) path for
NEW wallets — see `moolahub-noncustodial-custody.md`. The guidance below still holds
for the LEGACY server-custody wallets that remain (and for any wallet while the
non-custodial flag is off): harden them with step-up rather than assuming the
redesign protects them.

Decision: for a fully server-custodied EVM wallet (backend generates/stores/decrypts every private key and signs on-chain txs), do NOT chase a full non-custodial redesign (client-side/Privy signing) unless truly required. A raw DB+env compromise defeats any in-app gating regardless — the attacker can decrypt/sign outside the app. So the actionable, in-scope hardening target is app-level fund exfiltration via a merely-stolen session: any route that moves funds off-platform or auto-liquidates a balance must require fresh step-up proof (reuse `verifyStepUp`/`useStepUpGate`), not just `requireAuth`.

**Why:** the task explicitly said harden the existing app rather than introduce a new custody architecture; the highest-value gap was an arbitrary-destination withdraw endpoint with no reauth check.

**How to apply:** any new or existing route that (a) sends funds to a user-supplied address, or (b) deletes/releases a balance-holding entity (goal delete auto-withdraws), must call `verifyStepUp(user, body)` before executing, and the frontend mutation must call `useStepUpGate().requestProof()` first and merge the proof fields into the request body. Also: audit-log every private-key decryption (`getSigningSecret(userId, reason)`) with a reason string identifying the calling flow, for forensic detection if it's ever invoked from an unexpected path. Finally, grep marketing/UI copy for "non-custodial" / "you hold the keys" claims whenever touching wallet code — this app's copy had drifted to falsely claim non-custodial security while the backend fully custodies keys; keep copy honest about what actually protects funds (step-up confirmation, not key ownership).
