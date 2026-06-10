---
name: MoolaHub streaks model
description: How the savings streak works — single account-level frequency-based streak, not per-goal/per-circle
---

## Model
- There is ONE streak per user: account-level, frequency-based. NOT per-goal or per-circle. The streak row uses `commitmentType='account'`, `commitmentId=userId`.
- **Why:** the user explicitly chose "one account streak" — a single flame kept alive by ANY qualifying deposit (goal allocation OR circle contribution) within the chosen calendar window. Per-goal/per-circle streaks were retired and legacy rows archived.
- Frequency is daily / weekly / monthly (default **weekly**), stored on `users.streakFrequency` (+ `streakFrequencyLastChanged`). Changeable **once per calendar year** (`canChangeFrequency` / `nextChangeYear` in the overview). Re-anchoring on change keeps the current count.
- Periods are calendar-aligned in the user tz (Mon-start weeks). A streak only breaks when a whole window is missed (vacation pauses, freezes protect a single missed period).

## Engine entry points (streaks.ts)
- `recordSave(userId, saveRef, at?)` is the single hook callers use; goals.ts and circles.ts call it with the ledger txn id after a successful deposit. (Signature is `(userId, saveRef)` — not per-commitment.)
- `setStreakFrequency` enforces once/calendar-year, no-ops on same value, re-anchors keeping count.
- `getStreakOverview` returns the `StreakOverview` shape: `hero` (nullable), `frequency`, `canChangeFrequency`, `nextChangeYear`, `currentPeriodEnd`, `currentPeriodSatisfied`, `atRisk`, `lifetimeBest`, `totalPeriodsSaved`, `commitments` (now ALWAYS `[]`), `freezes`, `badges`, `badgeProgress`, `reminderOptIn`, `vacation`.

## Badges
- Quarterly badges; tier from completed quarters: **Bronze 1–3, Silver 4–7, Gold 8+** (`tierForCount` in StreakBadges.tsx). `badgeProgress` carries `earnedQuarters`, `nextTier`, `pct`, `daysToNext` for progress-to-next.

## Frontend wiring (must keep in sync)
- Any deposit success path (goal allocate, circle contribute) must `invalidateQueries(getGetStreaksQueryKey())` and fire a positive streak toast, else the dashboard/streak screen show stale counts.
- Unit text comes from `streakUnit(frequency, count)` / `periodNoun(frequency)` in StreakFlame.tsx — use these everywhere a count is rendered so daily/weekly/monthly read correctly.
- Frequency settings live at `/profile/streak` (linked from profile.tsx settings list).
