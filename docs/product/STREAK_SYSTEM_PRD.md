# MoolaHub Savings Streaks — Product Requirements Document

**Status:** Draft v1 for review
**Author:** Product / Lead Dev (ex-Snapchat)
**Audience:** Eng, Design, Data, Legal/Compliance
**Related:** goals, Susu circles, the double-entry ledger (`transactions`/`contributions`)

> **The core bet, in one line:** reward the *habit* of saving, never the *amount* — a flame you keep by saving once per your own chosen cadence, that's a joy to share and impossible to feel ashamed of.

---

## 0. The design thesis (read first)

Streaks are the most powerful habit mechanic in consumer apps (Snapchat, Duolingo) — and the most dangerous to get wrong in a *financial* app. The failure mode isn't low engagement; it's **manufactured anxiety that pushes people to move money they shouldn't**. So the whole system is built on four non-negotiable principles:

1. **Earned by real money movement, never purchasable.** A streak reflects an actual save into a goal or circle. You can't buy a flame.
2. **The cadence is the user's, not ours.** A streak period is defined by *each commitment's own frequency* (a weekly goal → weekly; a monthly circle → monthly). Monthly savers are first-class. There is **no global daily streak**.
3. **Loss is recoverable and never shaming.** Freezes, vacation mode, and at most one gentle nudge per period. We celebrate saving; we never guilt-trip a miss.
4. **Reward the behavior, not the balance — and measure it in time, not frequency.** Rewards are purely cosmetic, and a badge is earned by *calendar duration* of an unbroken streak, so a daily, weekly, and monthly saver all earn the **same badge for the same 3 months** maintained. We never give more for saving more often or saving more money.

Everything below serves those four principles.

---

## 1. Problem statement

MoolaHub helps people save toward goals and in Susu circles, but saving is a quiet, invisible act — there's no lightweight, emotionally rewarding loop that pulls someone back to make the *next* save, and nothing that lets a proud saver show their progress the way Strava lets a runner share a run. Without a habit loop, consistency (the single biggest driver of savings outcomes and retention) is left to willpower. The cost of not solving it: weaker week-over-week retention, lower contribution consistency in circles (which directly threatens circle completion), and no organic, user-driven growth.

---

## 2. Goals

1. **Improve saving consistency.** Increase the share of active commitments (goals + circle memberships) that receive an on-time save each period by **+15 pts** within 90 days of launch.
2. **Lift retention via a habit loop.** Improve D30 retention of users who start ≥1 streak by **+10 pts** vs. a holdout.
3. **Drive organic growth through sharing.** Achieve a **≥12%** share rate on milestone moments, with measurable installs/signups attributed to shared cards.
4. **Do no harm.** Keep average deposit size and deposit frequency within a healthy band — **no increase in same-day reversals/withdrawals** or support contacts citing pressure. (Guardrail metric, must not regress.)

---

## 3. Non-goals (v1)

1. **No global daily streak.** We will not force a once-a-day cadence — it's the overbearing trap for a savings app.
2. **No monetary rewards** (fee discounts, yield boosts, cash). v1 is cosmetic-only to avoid incentivizing risky saving. Revisit deliberately later.
3. **No friend streaks / leaderboards / social graph** in v1. Sharing is one-directional (export a card). Two-way friend streaks are a fast-follow (§12).
4. **No new "check-in" action.** Streaks are derived from saves users already make; we don't add a daily tap-to-keep-it ritual.
5. **No streak on raw wallet deposits.** Depositing into the wallet isn't "saving"; the streak counts commitment saves (goal allocations, circle contributions). Prevents gaming via deposit-and-withdraw.

---

## 4. The streak model (the heart of the build)

### 4.1 What counts as a "save"
A **save event** is money committed toward a savings intent:
- a **goal allocation** (ledger transaction type `goal_allocate`), or
- a **circle contribution** (a row in `contributions`).

Raw wallet deposits, withdrawals, releases, and payouts do **not** count.

### 4.2 The period is per-commitment (the key decision)
Every streak is tracked **per commitment** at that commitment's own cadence:
- A **goal** has a `frequency` (weekly / biweekly / monthly) → its streak period is that interval.
- A **circle** membership's period is its **round** cadence (`circle.frequency`); contributing in a round on time maintains the circle streak.

A commitment's **streak count** = the number of *consecutive periods* in which at least one qualifying save occurred. One save anywhere in the period keeps the flame — amount is irrelevant.

### 4.3 The headline number
Each user sees a single **hero flame** = their **longest currently-active commitment streak**, plus a lifetime stat ("**N periods saved**, never broken / best 26"). Per-commitment streaks appear on each goal/circle detail screen. This gives one satisfying number without inventing an artificial global cadence.

### 4.4 Period boundaries & timezones
- Periods are anchored to the commitment's `startDate` (or first save) and advance by its frequency; evaluated in the **user's local timezone** (store `tz` on the user; default from device).
- A period is "satisfied" the moment a qualifying save lands in it. A period "closes" at its boundary; if unsatisfied → streak is at risk → protections apply (§4.5) before it breaks.

### 4.5 Protections (selected: freezes, 1 reminder/period, vacation)
- **Streak freeze (1 per quarter):** if a period closes unsatisfied, an available freeze is **auto-consumed** to preserve the streak (the period shows as "frozen," not saved). A user receives **1 freeze every 3 months (max 4 per year)**, and **at most one freeze can be consumed within any rolling 3-month window** — enough to forgive an occasional slip, not so many that the streak becomes meaningless. Freezes don't stack indefinitely and are never purchasable.
- **Vacation / pause mode — 1 per year, up to 1 month:** a user can pause their streak(s) for a single planned break of **up to 30 days, once per calendar year**. Paused periods don't count for or against the streak; the flame resumes on return. Clear, one-tap, reversible (ending early forfeits the rest of that vacation, and the once-per-year allowance is still spent).
- **One reminder per period, opt-in.** A single "Streak Alert" nudge per period, only if the user enabled it and hasn't yet saved, sent at a sensible local time before the period closes, respecting quiet hours. Never more than one; never guilt-toned.
- **No purchasable repair in v1** (freezes cover the gentle-recovery need). A manual "repair" is a P2.

### 4.6 What a broken streak feels like
If a period closes unsatisfied and no freeze/vacation applies, the streak resets to 0 — but the UI frames it as **"start a new streak"** (recoverable, encouraging), surfaces the **lifetime best** prominently, and never uses loss-shaming language. The previous best is preserved as a badge.

---

## 5. User stories

**Saver (primary)**
- As a goal saver, I want a flame that grows each period I save so that I feel momentum without being told to save daily.
- As a monthly saver, I want my once-a-month contribution to fully count so that I'm not penalized for a slower, healthy cadence.
- As a busy user, I want a freeze to quietly cover a missed period so that one slip doesn't erase months of progress.
- As someone taking a planned break, I want to pause my streak so that I don't feel punished for life happening.
- As a privacy-conscious user, I want to share a milestone *without revealing how much I have* so that I can celebrate safely.

**Circle member**
- As a circle member, I want contributing on time to build a circle streak so that my reliability is visible to me and (opt-in) my circle.

**Sharer (growth)**
- As a proud saver, I want a beautiful milestone card I can post to my story so that I can share my journey like a Strava run.

**Edge cases**
- As a user with no active commitments, I see an empty state that invites me to start a goal (no flame yet, no pressure).
- As a user who just broke a streak, I see "start a new streak" + my best, not a failure screen.
- As a user who deleted the goal that held my best streak, my lifetime best and badges persist on my profile.

---

## 6. Requirements

### Must-have (P0) — the minimum that delivers the habit loop
- **P0-1 Streak engine (per-commitment, per-cadence).** Compute and persist a streak per goal and per circle membership from real save events.
  - Given a goal with weekly frequency, when the user makes ≥1 allocation in a week, then that goal's streak increments by 1 for that period and won't increment again until the next period.
  - Given a period closes with no qualifying save and no protection, then the streak resets to 0 and the prior value is recorded as that commitment's best.
  - Amount of the save never affects the streak (1 cent and 1,000 USDC are equal).
- **P0-2 Hero flame + lifetime best.** Show the user's longest active streak as the headline, plus lifetime best and total periods saved.
  - Given the user has streaks of 3 (goal A) and 7 (circle B), then the home flame shows 7.
- **P0-3 Per-commitment streak display.** Each goal/circle detail shows its own current streak, period status (saved / at-risk / frozen / paused), and best.
- **P0-4 Freezes (1 per quarter).** Grant 1 freeze every 3 months (max 4/year); auto-consume to save a closing unsatisfied period; at most one consumed per rolling 3-month window.
  - Given a period closes unsatisfied and a freeze is available (and none used in the last 3 months), then exactly one freeze is consumed, the streak is preserved, and the period is marked "frozen."
  - Given no freeze is available, then the streak breaks per P0-1.
- **P0-5 Vacation/pause (1/year, ≤1 month).** User can take one vacation per calendar year, up to 30 days, that pauses streak evaluation; paused periods are neutral (neither save nor break).
  - Given the user has not vacationed this calendar year, when they start a vacation (≤30 days), then evaluation is paused for that window and no period breaks the streak.
  - Given the user already vacationed this calendar year, then a second vacation is refused until the next year.
- **P0-6 One opt-in reminder per period.** A single pre-close nudge when enabled and unsaved, respecting quiet hours; never more than one per period.
- **P0-7 Milestone moments + shareable card.** At each **3-month maintained-streak milestone**, surface a celebration and a **shareable image/story card** (time saving, badge earned) with **amounts hidden by default**.
- **P0-8 Time-based, yearly-unique badges.** A badge is earned for every **3 months** of unbroken streak (4 per year), **identical for daily, weekly, and monthly savers** (measured by calendar duration, not period count). **Each calendar year has its own unique badge set** (collectible). Earned badges persist on the profile forever, even if the streak later breaks or the commitment ends.
  - Given two users — one saving daily, one saving monthly — who each maintain an unbroken streak for 3 months, then both earn the same Q-badge for that year.
  - Given the user earned the 2026 Q1 badge, then in 2027 the Q1 badge is a different, unique design.
- **P0-9 Ethical + privacy guardrails.** Sharing is opt-in; amounts hidden by default; no guilt-toned copy; streaks never purchasable; deposit/withdraw can't game it.

### Nice-to-have (P1) — fast follows
- **P1-1 Circle-level shared streak** (the circle keeps a flame if every member contributes on time) + opt-in visibility to members.
- **P1-2 Streak insights** ("you've saved 12 weeks straight — that's $X toward Vacation") in-app only.
- **P1-3 Auto-save ↔ streak linkage:** if a user has auto-save on, a successful auto-save satisfies the period automatically (reduces breaks).
- **P1-4 Richer card themes** + animated story export.

### Future considerations (P2) — design for, don't build
- **P2-1 Friend streaks** (Duolingo-style, mutual) + invite flow.
- **P2-2 Leaderboards** within a circle or friends.
- **P2-3 Streak repair** (manual catch-up within a grace window).
- **P2-4 Monetary perks** (fee discount/yield boost) — only after a deliberate ethics + compliance review.
- **P2-5 "Streak Society" tier** at a high milestone with exclusive cosmetics.

> Architectural insurance: model streaks as a generic ledger of period outcomes per (user, commitment) so friend streaks, circle streaks, and leaderboards (P1/P2) are reads over the same data — don't hard-code a single global counter.

---

## 7. Data model (maps to the existing schema)

New tables (Drizzle/Postgres), additive — no changes to money tables:

- `streaks` — one row per (user, commitment): `id, userId, commitmentType ('goal'|'circle'), commitmentId, frequency, currentCount, bestCount, status ('active'|'frozen'|'paused'|'broken'), currentPeriodStart, currentPeriodEnd, currentPeriodSatisfied (bool), lastSaveTxId, updatedAt`.
- `streak_periods` — append-only outcome log: `id, streakId, periodStart, periodEnd, outcome ('saved'|'frozen'|'paused'|'missed'), saveCount, createdAt`. (Drives history, cards, and future leaderboards; idempotent.)
- `streak_freezes` — `id, userId, balance, lastGrantedAt, lastUsedAt, grantedTotal, usedTotal, updatedAt`. Accrual is calendar-based: grant 1 every 3 months (max 4/year); enforce "≤1 used per rolling 3-month window" via `lastUsedAt`.
- `streak_badges` — `id, userId, badgeKey, year, quarterIndex (1–4), earnedAt, sourceCommitmentId` (cosmetic, persistent). `(badgeKey)` encodes the yearly-unique design; `(year, quarterIndex)` is the collectible slot.
- `user` gains `timezone`, a `streak_reminder_opt_in` flag (mirrors the "Streak Alert" toggle), and vacation tracking: `vacation_start`, `vacation_end`, `vacation_year_used` (the calendar year the single annual vacation was spent). Enforces 1/year, ≤30 days.

Save events already exist: goal allocations are `transactions.type = 'goal_allocate'`; circle contributions are `contributions` rows. The engine reads these — it does not duplicate money state. The double-entry ledger remains the source of truth for money; streaks are a derived, non-financial projection.

---

## 8. Technical design

- **Two write paths feed the engine:**
  1. **On save (real-time):** in `allocateToGoal()` and `contribute()`, after the ledger commit, call `recordSave(userId, commitment, txId)` which marks the current period satisfied and increments the streak if this is the period's first qualifying save. Idempotent and inside/after the same logical operation.
  2. **On period close (scheduled):** a daily job (`evaluateStreaks`) advances any streak whose `currentPeriodEnd` has passed: if satisfied → roll forward; else apply freeze → else pause check → else break. Runs per user timezone; idempotent via `streak_periods` (a period is evaluated once).
- **Badges & freezes are calendar-time based (not period-count).** Track each streak's `startedAt`. The job awards the next badge when `now − startedAt` crosses a 3-month boundary while unbroken — so daily, weekly, and monthly savers all earn at the same calendar time — tagged `(year, quarterIndex)` from the current year's unique set. Freezes accrue 1 per 3 months (cap 4/year), with ≤1 consumed per rolling 3-month window via `lastUsedAt`. A break resets badge-progress *timing* but never removes earned badges.
- **Timezone:** evaluate using the user's `timezone`; default to UTC if unknown, capture device tz at signup.
- **Reminders:** the same scheduled job enqueues at most one reminder per (streak, period) for opted-in users with an unsatisfied period approaching close, via the existing `notify()`/notifications pipeline; dedupe on `(streakId, periodStart)`.
- **Frontend (React):** a `useStreak()` hook + a `StreakFlame` component (hero on dashboard, compact on goal/circle detail), a milestone celebration modal, and a `ShareCard` generator (render to canvas/PNG client-side; no amounts unless opted in).
- **Performance/abuse:** streak writes are O(1) per save; the daily job is bounded by active commitments. Because only `goal_allocate`/`contributions` count and raw deposits don't, deposit-withdraw loops can't farm streaks.
- **Backend stack:** Express + Drizzle (same as the app); add a `lib/streaks.ts` module + a `routes/streaks.ts` (`GET /streaks`, `POST /streaks/:id/pause`, `POST /streaks/reminders`), all behind `requireAuth` and scoped by `userId`.

---

## 9. Sharing (Strava-style, privacy-first)

- **Milestone card** generated at each **3-month maintained-streak milestone** (3, 6, 9, 12 months …). Card shows: the flame + that year's badge, "**N months saving**," commitment name (user can hide), an optional goal emoji/photo, MoolaHub branding. **Amounts are hidden by default**; a toggle lets the user reveal "saved $X" before sharing.
- **Share targets:** native share sheet (Instagram/WhatsApp/X/Stories), download image, copy link. A shared link deep-links to a branded landing → app install/signup (growth attribution via UTM/referral code).
- **Consent:** nothing is shared automatically; every share is an explicit user action. No friend can see your streak in v1.

---

## 10. Rewards — time-based, yearly-unique badges (v1)

Cosmetic only, earned by **calendar duration** of an unbroken streak — the cadence (daily/weekly/monthly) does not change the timing:
- **A badge every 3 months maintained → 4 badges per calendar year** (Q1–Q4). Same 3 months of saving earns the same badge whether you save daily, weekly, or monthly.
- **Each year's set of 4 badges is unique and collectible** (the 2026 set ≠ the 2027 set). Maintaining a year-long streak completes that year's collection — a strong, healthy reason to come back year after year.
- **Earned badges persist forever** on the profile, even if the streak later breaks or the commitment ends. A break resets progress *toward the next* badge but never removes earned ones; freezes (§4.5) are what protect in-progress badge time.
- Badges carry **no monetary value or product privilege** in v1 — by design.
- Final names/visuals are a Design + brand decision (Q1); the mechanic is fixed: 3-month cadence, 4/year, yearly-unique.

---

## 11. Success metrics

**Leading (days–weeks):**
- Streak adoption: % of active savers with ≥1 active streak (target **≥60% in 30 days**).
- On-time save rate per period: baseline +15 pts (Goal 1).
- Freeze usage rate and break rate (health signals; watch for break rate that signals an overbearing cadence).
- Reminder opt-in rate and reminder→save conversion.
- Milestone share rate (target **≥12%** of milestone moments).

**Lagging (weeks–months):**
- D30 retention lift for streak-starters vs. holdout (target **+10 pts**).
- Circle completion rate (contributions consistency → fewer stalls).
- Installs/signups attributed to shared cards (k-factor contribution).

**Guardrail (must not regress):**
- Same-day deposit→withdraw reversals; average deposit size; support contacts citing pressure/anxiety. If any worsens, soften cadence/reminders.

Measurement: event instrumentation on save, period close, freeze, pause, milestone, share; weekly review for 4 weeks, then monthly.

---

## 12. Phasing

- **v1 (this PRD):** per-commitment streaks, hero flame, freezes, vacation, 1 reminder/period, milestone cards, cosmetic tiers, guardrails.
- **Fast-follow (P1):** circle shared streak, auto-save linkage, insights, richer cards.
- **Later (P2):** friend streaks + invites, leaderboards, manual repair, (only after review) monetary perks, Streak Society.

---

## 13. Open questions

| # | Question | Owner | Blocking? |
|---|----------|-------|-----------|
| Q1 | Final milestone thresholds & tier names/visuals. | Design + Brand | Before build of §9/§10 |
| Q2 | Freeze economics confirmed: 1 per 3 months, max 4/year, ≤1 per rolling 3-month window. Tune the cap only with data. | Product + Data | Resolved (tunable) |
| Q3 | Headline = longest active streak vs. a separate "any-save" rollup — confirm longest-active. | Product | Before P0-2 |
| Q4 | Compliance review of streak/share copy for consumer-protection (UDAAP-style) language — no pressure, no guarantees. | Legal | Before launch |
| Q5 | Reminder default time per cadence + quiet-hours policy. | Design + Data | Before P0-6 |
| Q6 | Does an auto-save satisfy the period in v1 or P1? (Recommend P1.) | Product + Eng | Before P1-3 |

---

## 14. Appendix — edge cases the engine must handle
- New commitment: streak starts at 0; first save in the first period → 1.
- Multiple saves in one period: streak +1 once; extra saves logged but don't multiply.
- Commitment completed/closed (goal reached, circle finished): freeze the streak as a final "best," award any milestone badge, stop evaluating.
- Goal deleted: streak row archived; lifetime best + badges persist on profile.
- Frequency changed mid-streak: apply new cadence from the next period; don't retroactively break.
- Clock/timezone travel: evaluate on user tz; never double-count or double-break a period (idempotent `streak_periods`).
- Backfill/migration: optionally seed initial streaks from historical `goal_allocate`/`contributions` so launch isn't a cold start (decide in Q-bus).
- Badge timing is cadence-independent: a daily, weekly, and monthly saver each earn their 3-month badge at the same calendar point; the engine uses elapsed time, not number of periods.
- Break then restart: earned badges persist; the "months toward next badge" counter resets to 0 and re-accrues from the new streak start.
- Year rollover: a streak that crosses into a new calendar year earns the *new* year's unique badge for its next 3-month milestone; a continuous multi-year streak therefore collects each year's distinct set.
- Freeze rate-limit: a second miss within the same rolling 3-month window cannot be frozen even if a balance exists — it breaks the streak (prevents freezes from making streaks meaningless).
- Vacation: at most one per calendar year, ≤30 days; during vacation no period saves or breaks the streak, and badge-progress time is paused (it does not count toward the next 3-month badge). The annual allowance resets on Jan 1 (user's timezone).

