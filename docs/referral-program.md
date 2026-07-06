# MoolaHub Refer & Earn

> Turn your circle into your income. Invite friends to save on MoolaHub and earn a
> share of the platform fees they generate — automatically, on-chain, forever.

MoolaHub is a USDC savings and Susu (rotating savings) platform built on Monad.
**Refer & Earn** rewards members who grow the community: when someone you invite
saves toward a goal or completes a Susu round, MoolaHub collects a small platform
fee — and you keep a percentage of it. The more of your referrals who stay
*active savers*, the higher your share climbs, up to **20%**.

This document is the complete program specification: the rules members see, and
the mechanics that back every cent with a real, auditable ledger entry.

---

## 1. At a glance

| | |
|---|---|
| **What you earn** | A percentage of the platform fees your referrals generate |
| **Base rate** | 10% of eligible fees |
| **Maximum rate** | 20% of eligible fees |
| **How the rate grows** | By your number of *active* referred savers (see Tiers) |
| **Minimum withdrawal** | $100 per calendar month |
| **Maximum withdrawal** | $1,000 per calendar month |
| **Payout asset** | USDC, sent straight to your wallet on Monad |
| **When you earn** | The moment a referral's fee settles on-chain |

There is no cap on how many people you can refer, and no cap on lifetime
earnings — only a monthly ceiling on how much you can withdraw at once.

---

## 2. How it works

### 2.1 Get your link
Every member has a unique referral code and a shareable link:

```
https://<your-moolahub-domain>/register?ref=YOURCODE
```

Your code is generated the first time you open **Refer & Earn** and never
changes. Share the link anywhere — WhatsApp, X, your Susu group chat.

### 2.2 Your friend joins
When someone signs up through your link, they're permanently attributed to you as
their referrer. Attribution is:

- **One referrer per person.** The first valid link a new member uses is locked
  in at sign-up and never changes.
- **Set once, at sign-up.** It cannot be added or reassigned afterward.
- **Self-referral proof.** You cannot refer yourself; invalid or self-referral
  codes are ignored silently and never block a sign-up.

### 2.3 Your friend saves, you earn
Whenever your referral generates an eligible platform fee — by withdrawing from a
savings goal, or by receiving a Susu payout — MoolaHub credits your referral
balance with your tier percentage of that fee. Earnings are:

- **Real, not promotional.** Every credit is backed by a fee MoolaHub actually
  collected and a matching double-entry ledger posting.
- **On-chain settled.** A fee only becomes a *confirmed* earning once its
  underlying transaction settles on Monad. Until then it shows as **Pending**.
- **Automatic.** There is nothing to claim. A background process sweeps confirmed
  fees continuously and books your commission.

### 2.4 Withdraw to your wallet
Once you have at least **$100** of available earnings, you can withdraw to your
MoolaHub wallet as USDC (subject to the monthly limits in §4). Withdrawals
require a fresh security check (your password and/or two-factor code), exactly
like any other money-moving action on MoolaHub.

---

## 3. Earning tiers — the Active Saver Boost

Your commission rate is not fixed. It rises with the number of your referrals who
are **active savers** — people you invited who are currently keeping a savings
streak alive. This rewards quality over quantity: inviting people who genuinely
save earns you more than inviting people who sign up and disappear.

| Tier | Active referred savers | Your share of eligible fees |
|------|------------------------|-----------------------------|
| **Starter** | 0 – 5 | **10%** |
| **Builder** | 6 – 20 | **12.5%** |
| **Connector** | 21 – 50 | **15%** |
| **Leader** | 51 – 100 | **17.5%** |
| **Champion** | 100+ | **20%** (max) |

### What counts as an "active saver"?
A referral is an **active saver** when they have a live MoolaHub savings streak —
that is, they've made a qualifying deposit (into a goal or a Susu circle) within
their current streak window and their streak has not lapsed. Members who sign up
but never save, or whose streak has broken, still count toward your *total
referrals* but not toward your *active* count that sets the tier.

### When the rate is applied
Your tier is evaluated **at the moment each earning is booked**, using your active
count at that time, and the rate is **locked into that earning**. Growing your
tier lifts the rate on *future* fees; it never retroactively re-rates fees you've
already earned on. This makes every earning deterministic and auditable.

---

## 4. Withdrawals

| Rule | Value |
|------|-------|
| Minimum per withdrawal | **$100** |
| Maximum per calendar month | **$1,000** |
| Asset | USDC on Monad |
| Destination | Your linked MoolaHub wallet |
| Security | Step-up reauthentication required |

- The **$1,000 monthly maximum** is the sum of all referral withdrawals within a
  single calendar month (UTC). Once you've withdrawn $1,000 in a month, further
  withdrawals are blocked until the next month begins.
- Each individual withdrawal must be at least **$100**. If your remaining monthly
  allowance is below $100, you must wait for the next calendar month.
- You can only withdraw **available** earnings (confirmed and not yet withdrawn).
  Pending earnings become withdrawable once they settle on-chain.
- Withdrawals require a **wallet**. Set one up in the Wallet section first.

Earnings that are not withdrawn simply remain in your referral balance — there is
no expiry.

---

## 5. What generates a fee (and therefore an earning)

MoolaHub charges a flat **2% platform fee** on two events. Your referral earns
you a share of exactly these:

1. **Savings goal withdrawals.** When a referral withdraws from a savings goal,
   MoolaHub takes 2% of the gross amount. Your commission is your tier % of that
   2% fee.
2. **Susu (circle) payouts.** When a referral receives their payout from a Susu
   circle, MoolaHub takes 2% of the pot. Your commission is your tier % of that
   fee.

Deposits, contributions, transfers between your own balances, and faucet/test
actions **do not** generate fees, and therefore do not generate referral
earnings. Fees — and earnings — only exist when on-chain settlement is enabled.

### Worked example
Your referral withdraws **$500** from a savings goal.

- MoolaHub fee (2%): **$10.00**
- You are a **Builder** (6–20 active savers → 12.5%)
- Your earning: 12.5% × $10.00 = **$1.25**

If you were a **Champion** (100+ active savers → 20%), the same event would earn
you **$2.00**.

---

## 6. Earnings states

| State | Meaning |
|-------|---------|
| **Pending** | A referral generated a fee, but it hasn't settled on Monad yet. Displayed for transparency; not yet withdrawable. |
| **Available** | Settled and booked to your referral balance. Withdrawable, subject to monthly limits. |
| **Lifetime** | The total you've ever earned (available + already withdrawn). |

---

## 7. Your dashboard

The **Refer & Earn** page shows:

- Your **referral code** and one-tap **copy link** / share.
- Your current **tier**, rate, and how many more active savers unlock the next
  tier.
- **Pending**, **Available**, and **Lifetime** earnings.
- **Active** vs **total** referrals.
- A **referrals list** showing each person you invited: their status
  (active / inactive / pending), their savings activity level, and the fees
  you've earned from them.
- **Withdraw** controls with your remaining monthly allowance.

### A note on privacy
MoolaHub never shows you another member's account balances or dollar savings
amounts — not even for people you referred. Your referrals list shows a person's
*activity level* (whether they're actively saving and how strong their streak is)
and the commission **you** earned from them, but never their private financial
details.

---

## 8. Program integrity & fair use

- **Real referrals only.** Attribution is one-to-one and permanent; you cannot
  refer yourself or reassign a referral.
- **Backed by real fees.** Every earning corresponds to a fee MoolaHub actually
  collected and settled on-chain. There are no promotional or phantom credits.
- **Idempotent accounting.** Each fee can produce at most one earning. The system
  is designed so that retries, restarts, or duplicate processing can never
  double-credit you.
- **Auditable.** Every earning and withdrawal is a double-entry ledger
  transaction. Balances are always derived from the ledger, never edited by hand.
- MoolaHub may adjust program parameters (rates, tiers, limits) with notice.
  Abuse — fake accounts, self-dealing, or gaming the active-saver definition — may
  result in forfeiture of referral earnings.

---

## 9. FAQ

**Do I earn on my own savings?**
No. You earn on the *fees your referrals generate*, not on your own activity.

**When exactly do I get paid?**
Your commission is booked automatically as soon as a referral's fee settles
on-chain. You then withdraw it to your wallet whenever you like (min $100/month,
max $1,000/month).

**Does my rate apply to past earnings when I level up?**
No. Each earning locks in the rate you had when it was booked. Leveling up
increases the rate on *future* earnings.

**What happens to a referral who stops saving?**
They still count as one of your total referrals, but they no longer count toward
your *active* saver tier, so they don't help raise your rate until they start
saving again.

**Is there a limit on how much I can earn?**
There's no cap on lifetime earnings — only a $1,000 per-month withdrawal ceiling.

**What if a payout fails on-chain?**
If an earning's underlying fee never settles, that earning never becomes
available. If a withdrawal fails to send, the amount is returned to your referral
balance.

---

## 10. Technical appendix (for maintainers)

This section documents the implementation so the program stays auditable.

### Data model
- **`referral_codes`** — one row per user: their unique, immutable code.
- **`referrals`** — one row per attributed sign-up: `(referrerId, refereeId)` with
  `refereeId` unique (one referrer per person). Created at sign-up.
- **`referral_earnings`** — the accrual log. One row per processed fee
  transaction, keyed uniquely on `sourceTransactionId` for idempotency. Records
  `feeCents`, `rateBps` (locked at accrual), `commissionCents`, and a `status`
  of `earned` (a referrer got commission) or `skipped` (fee had no referrer;
  logged so it's never re-scanned).
- **`referral_withdrawals`** — one row per withdrawal, with the `YYYY-MM` period
  used to enforce the monthly cap.

### Ledger
A new account key, `referral:<userId>`, holds a member's earned commission.
It is additive and invisible to existing balance sums (wallet balances only sum
`wallet:` postings and `type='yield'`), so introducing it cannot affect any
existing balance, dashboard, or test.

- **Accrual** transfers `fees → referral:<referrer>` (goal fees) or
  `external → referral:<referrer>` (circle fees) — i.e. from whichever account
  the fee actually landed in — plus an inserted `referral_earnings` row, in one
  atomic transaction.
- **Withdrawal (on-chain enabled)** transfers `referral:<user> → external`,
  books the transaction `pending`, and enqueues an on-chain `payout` (platform →
  the user's wallet address) with memo `referral:<withdrawalId>`. The existing
  settlement reconciler confirms it; no reconciler changes are required.
- **Withdrawal (on-chain disabled / local)** transfers
  `referral:<user> → wallet:<user>` ledger-only, so it's visible in the offline
  ledger balance.

### Accrual sweep (not inline hooks)
Rather than hooking every fee-confirmation site (there are several), a single
idempotent `accrueReferralEarnings()` sweep runs on a background loop. It selects
**confirmed** `type='fee'` transactions with no matching `referral_earnings` row,
resolves the referee (goal fee → `txn.userId`; circle fee → the `payout`
transaction's recipient for the same `(circleId, round)`), resolves that referee's
referrer, computes the tier rate, and books the earning + ledger transfer in one
transaction. "Pending" earnings are derived read-only at display time from
unconfirmed fees and are never stored.

### Rate tiers (basis points)
`0–5 → 1000`, `6–20 → 1250`, `21–50 → 1500`, `51–100 → 1750`, `100+ → 2000`.
Active saver = an account-level savings streak (`commitmentType='account'`) with
status `active` or `frozen` and `currentCount > 0`.

### Security
`POST /referral/withdraw` is guarded by JSON+origin checks, authentication, and
**step-up reauthentication** (`verifyStepUp`) — the same protection as wallet
withdrawals. The monthly cap and the withdrawal row are enforced/inserted inside
the same database transaction as the ledger transfer, with `requireSufficientFrom`
preventing overdraw under concurrency.
