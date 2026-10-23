> Produced 2026-10-21 by a structured debate: Stellar and Base advocates, a neutral migration-cost estimator, a neutral Ghana money-rails researcher, rebuttals, 11 adversarial fact-checks, three lens judges (Ghana rails, engineering, risk) and a chief judge. Founder sign-off pending.

# ADR: Settlement chain: Base over Stellar

**Date:** 2026-10-21 · **Status:** Decided by the CTO panel (3–0). Founder sign-off pending.

## Decision
Build Moolahub's on-chain layer on Base (chain 8453). Keep the ramp layer chain-agnostic. The launch gate is a licensed Ghana MoMo partner, not the chain.

## Scorecard
Weights apply within each lens and add up to 1.0 per lens. Scores run from 1 to 5. All three judges chose Base. Stellar won two criteria (liveness and custody default) and tied one (regulatory path).

| Lens | Criterion | Wt | Stellar | Base |
|---|---|---|---|---|
| Ghana rails | MoMo cedi ramps (verified, has an API) | .25 | 2 | 4 |
| | Diaspora card and remittance inbound | .20 | 2.5 | 4 |
| | Regulatory path (Act 1154, Notice /14, sandbox) | .15 | 3 | 3 |
| | Non-custodial classification + ramp fit | .10 | 3 | 3.5 |
| | USDC where ramps settle | .10 | 4 | 5 |
| | Shippable within 12 months | .20 | 2 | 4 |
| | **Lens total** | | **2.55** | **3.90** |
| Engineering | Code reuse / migration size | .30 | 1 | 4 |
| | Wallet SDKs (iOS/web, passkeys, sponsorship) | .20 | 3 | 4 |
| | Tooling, AI-assisted dev, maturity | .15 | 2 | 5 |
| | Audit cost and time to an audited ship | .15 | 2 | 3 |
| | Yield integration | .10 | 1 | 5 |
| | Ramp integration effort | .10 | 2 | 3 |
| | **Lens total** | | **1.80** | **4.00** |
| Risk | Security of user principal | .25 | 2 | 4 |
| | Chain liveness and upgrade control | .15 | 3.5 | 3 |
| | Vendor concentration | .15 | 2.5 | 3.5 |
| | Yield-source risk | .10 | 1.5 | 4 |
| | Custody classification / App Store | .15 | 3.5 | 3 |
| | Viability, lock-in, switching cost | .20 | 2 | 4.5 |
| | **Lens total** | | **2.48** | **3.73** |
| **Overall** (three lenses weighted equally) | | | **2.28** | **3.88** |

## Why
1. **Stellar has no Ghana MoMo rail.** *Fact-checked: the claim that it does was refuted.*
   - Paychant is a redirect widget with no stellar.toml. Its widget returned HTTP 502 today, and its SEP-24 anchor is still "being built".
   - MoneyGram is cash-out only in Ghana, paid at agents.
   - HoneyCoin is the only provider with documented GHS MoMo limits, and it is EVM-only. Fonbnk and Kotani support both chains.
   - Choosing Base loses no partner. Choosing Stellar loses HoneyCoin.
2. **We keep what we built.** *Fact-checked: partly true.*
   - What carries over: 2,256 Solidity lines, 2,144 Foundry test lines, the viem settlement layer, CI, and Privy's full EVM tier (gas sponsorship, Earn). The v1 contracts ran on Base Sepolia through 2026-07-02.
   - Stellar would need a rewrite: Soroban contracts are Rust-only, and Privy only signs on Stellar, with no sponsorship and no transaction sending.
   - "Config change" is true only for testnet.
   - The estimate of 12–20 engineer-weeks for Base against 24–40 for Stellar is unverified. It points the same way as the 8-day Base Sepolia→Monad move.
3. **Stellar's passkey advantage did not hold up.** *Fact-checked: refuted, and partly.*
   - Base has had the P256VERIFY precompile since its Fjord upgrade, and OpenZeppelin 5.5 adds SignerWebAuthn.
   - On Stellar, a passkey wallet cannot use a ramp today. SEP-45 (passkey account login) is still a draft, and MoneyGram has no endpoint for it. A ramp user would need a second key on a classic G-account.
4. **Yield depth.** *Fact-checked.*
   - Blend never went to zero; it still holds about $142M.
   - But its backstop is $0, the v2 pools are On Ice or Frozen, and only about $14.9M of USDC can be withdrawn.
   - Morpho on Base holds $4.49B.
5. **The Audit Bank saves cash, not time.** *Fact-checked: partly true.*
   - It requires an SCF award, a full rewrite and a readiness review, so the earliest realistic audit is Q1–Q2 2027.
   - A $15–40K Solidity audit on Base can land in 2–3 months.

## What we give up
- **Stellar funding:** the Audit Bank (saves about $15–40K on the audit) and SCF grants of up to $150K.
- **Stellar's recent liveness record.** I found no network halt since 2019, but later years were not checked. Base runs a single sequencer and had outages in Aug 2025 and Jun 2026.
- **An upgrade timelock.** Base has none. This is softened because upgrades need sign-off from an independent 8-of-11 Security Council.
- **A device-held passkey as the default signer.** On Base this is custom work.
- **Direct access to MoneyGram's cash-out network.**
- **Vendor spread:** we depend more on Coinbase, Circle and Privy.

## Hybrid options
- **Base core with chain-agnostic ramps: accepted.**
  - `ramp_orders` and funding sessions (iOS plan N13) carry a `chain` field.
  - CCTP reaches Stellar (Circle domain 27), so USDC from a future Stellar-only rail can arrive without a rewrite.
- **Base core with a Stellar/MoneyGram cash-out leg: deferred.**
  - Ghana is cash-out only.
  - It needs KYB, certification and a G-account key.
  - It adds bridge operations without any licensed benefit.
- **Stellar core with EVM yield: rejected.** It means a full rewrite plus a bridge, to get yield that is switched off for Ghana users anyway.

## Plan changes
**iOS (`docs/ios-app-plan.md`)**
- **Wallet SDK:** use the Privy Swift EVM wallet. Chain code stays in the wallet module, so this adds about 0 weeks.
- **Keep D4 (the user owns the wallet).** Do not adopt the Base plan §4 design that makes Moolahub's key the wallet owner (`base-mainnet-architecture.md:136`). Privy's own docs make that custodial.
- **Correct §7 (`:16`, `:99`).**
  - Act 1154 s.73 defines non-custodial in software-neutral terms.
  - Only the Schedule says "cold/hardware". Counsel decides which applies.
- **Keep D3.**
  - Card-funded diaspora users come first (Coinbase Onramp, MoonPay, Stripe).
  - Ghana residents stay in no-money mode until a licensed partner exists.
- **If counsel requires device-held keys:** run a 2-week passkey-signer spike using P256VERIFY and SignerWebAuthn.

**Backend (`docs/base-mainnet-architecture.md`, milestones M0–M8)**
- **Retarget from Monad.**
  - Replace `monadTestnet` in the 8 importing files, the env files and the explorer links.
  - Change the `wallets.network` default.
  - Update the "Current initiative" section of CLAUDE.md.
- **Remove server-held keys.**
  - Make `createPrivyWalletForUser` the only wallet path.
  - Retire the default server-generated keys (`wallet.ts:18-24`, `ENABLE_PRIVY_CUSTODY`) and migrate those rows.
- **Production settings.** Use real Circle USDC (`0x8335…2913`). Set OWNER, GUARDIAN and treasury explicitly, never the deployer.
- **Re-decide line 41.** Deploying the existing v1 contracts may give a smaller audit scope than the ~441-line CircleVault draft.
- **Indexer.** Fix its two security bugs before M4.
- **Yield.** Use only Morpho Prime (Gauntlet/Steakhouse) and Aave, and keep it off for Ghana users.
- **Legal gate.** Get counsel's opinion on Notice /14 and s.73 before any real cedis move.

## Revisit: re-check on 2027-01-15, or at the M6 audit gate if that comes first
Reopen the decision if any of these happen:
1. A BoG/SEC-authorised Ghana MoMo↔USDC partner settles only on Stellar and accepts passkey contract accounts (SEP-45), while HoneyCoin, Fonbnk and Kotani fail to get authorised.
2. Counsel rules that, in the next 12 months, the only lawful route is a licensed remitter that works only on Stellar. Or counsel rules that a user-owned Privy wallet is custodial but a Stellar passkey contract account is not, and the Base passkey-signer spike fails.
3. MoneyGram adds Ghana cash-in or MoMo payout with contract-account login, and remittance-to-cash becomes our core use case.
4. Base card on-ramps turn out to be unavailable in the UK, US and Canada, while buying Stellar USDC by card works there.
5. Base suffers a serious event (a malicious upgrade, or a sequencer outage lasting days), or Privy drops EVM gas sponsorship or Earn.
6. All of these together: an SCF award, admission to the Audit Bank, OpenZeppelin's Stellar contracts reaching 1.0, and a timed spike that ports the circle contracts to Soroban in 4 weeks or less.

## If the founder still prefers Stellar: minimum safe path
1. **Spike before any rewrite.** Two weeks covering:
   - a passkey contract account on iOS and web;
   - a fee-bumped USDC transfer;
   - an anchor round trip: SDF's test anchor via SEP-45, and MoneyGram via a G-account.

   If any part fails, go with Base.
2. **Funding first.** Submit to SCF #46 before 8 Nov 2026, and do not rewrite without funding.
3. **Keep the fallback.** Keep the Solidity code, its tests and the Base Sepolia deployment working. The ledger stays the source of truth.
4. **Port narrowly and safely.**
   - Port V1 only (about 1,046 lines), with no yield.
   - Pin the OpenZeppelin Stellar contracts version; v0.8.0 broke smart-account signing.
   - Handle Soroban state expiry so user principal can never be archived.
   - Allow no admin path to user principal.
5. **Accounts and reserves.** Hold no G-account keys on the server, and sponsor about 1.5 XLM of reserves per user.
6. **Mainnet gate and budget.**
   - Put no mainnet funds in before the Audit Bank audit is closed.
   - Budget 24–40 engineer-weeks (unverified) and a 1–3 month slip in the iOS timeline.