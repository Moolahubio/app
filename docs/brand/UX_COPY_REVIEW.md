# MoolaHub UX Copy Review & Rewrite

**Reviewed with:** `/design:design-critique` (clarity, hierarchy, consistency) + `/marketing:brand-review` (voice, terminology, compliance)
**Scope:** every user-facing string — login → every page → notifications & emails
**Goal:** sound like a real fintech/bank, written by people — not AI

---

## Summary

**Overall:** the bones are good (clear structure, friendly intent), but the copy reads "AI-generated" for four concrete, fixable reasons. None are about being friendly vs. formal — they're consistency and polish issues that banks/fintechs get right by default.

The biggest strengths: the core flows are labeled plainly, and the money notifications are specific (amounts + names). The most important fixes: kill the em-dash habit, make capitalization consistent (sentence case everywhere), drop emojis from money messages, and replace generic/chirpy phrases with concrete, calm ones.

### The four "AI tells" (root causes)
1. **Em-dash overuse.** 6 em-dashes in `circles.tsx`, 5 in `circle-detail.tsx`, etc. The em-dash-as-connector is the #1 machine-writing signature. Banks use periods and commas.
2. **Inconsistent capitalization.** Form labels are Title Case ("Goal Name", "Target Amount (USDC)", "Member Emails (comma separated)") while other UI is sentence case. Real product UIs pick one — **sentence case** — and never mix.
3. **Emojis in money messages.** "You received the pot! 🎉", "Your savings are back! 🎉". A bank never puts a party emoji on a transaction. It undercuts trust.
4. **Chirpy filler & vague claims.** "Understanding Blockchain (Simply)", "Keep your streak going — one lesson at a time.", "Save Now. Grow Together." Generic, not concrete; and a few phrases drift toward unsubstantiated financial claims (see Compliance).

---

## MoolaHub voice (use this for every string)

If MoolaHub were a person: a sharp, trustworthy friend who works in finance — explains money plainly, never hypes, never talks down, and is genuinely glad when you hit a goal.

| Attribute | We are | We are not | Sounds like |
|-----------|--------|-----------|-------------|
| Clear | plain, concrete, jargon-light | dumbed-down or vague | "Set a target and a date. We'll track it." |
| Trustworthy | calm, precise about money | salesy, hype-y, emoji-happy | "$980 was added to your available balance." |
| Warm | encouraging, human | chirpy, childish, exclamatory | "Nice — you've saved 4 weeks in a row." |
| Confident | direct, verb-first | hedging or padded | "Start a circle" not "Let's get you started!" |

### Style rules (the fix list — apply globally)
- **Sentence case** for all labels, headings, buttons, toasts. Never Title Case. ("Goal name", not "Goal Name".)
- **Em-dash diet:** at most one per screen, and never as a default connector. Prefer a period or comma.
- **No emoji in money or transactional copy.** (If you ever use one, reserve it for non-money learning/celebration — but default to none for a banking feel.)
- **Exclamation marks are rare** and never on a money movement. Calm confidence reads as trustworthy.
- **Verb-first CTAs**, consistent across the app: "Create goal", "Start circle", "Add money", "Send", "Withdraw".
- **Numbers/currency** formatted consistently: `$1,000`, `100 USDC`, `2%`.
- **Cut filler:** "Simply", "one lesson at a time", "in minutes" (unless literally true), "Let's…".
- **Terminology, used consistently:** sign in / sign up (verbs), wallet, circle (define "Susu" once), goal, available balance, contribution, round. Don't switch synonyms.

---

## Detailed findings

| # | Issue | Location | Severity | Fix |
|---|-------|----------|----------|-----|
| 1 | Party emojis on money notifications | `lib/circles.ts` payout notifs | High | Remove emoji; calm, specific wording |
| 2 | Title Case form labels mixed with sentence case | goals, circles, wallet forms | High | Sentence case everywhere |
| 3 | Em-dash overuse as connector | most pages | Medium | Periods/commas; ≤1 per screen |
| 4 | Vague/chirpy marketing & filler | login, learn, dashboard | Medium | Concrete, calm rewrites |
| 5 | Inconsistent CTA verbs ("Create a goal" / "Create a savings goal" / "Start a new circle") | goals, circles | Medium | One pattern: "Create goal", "Start circle" |
| 6 | Parenthetical cleverness ("Understanding Blockchain (Simply)") | learn, lessons-data | Low | "Blockchain, explained simply" |
| 7 | Potential unsubstantiated financial claims ("Grow your money", "Grow Together", Yield APY) | login, profile | High (compliance) | Qualify or soften; see Compliance |

---

## Before → after, by screen

Format: ~~before~~ → **after**. Where a string is already good, it's omitted.

### Login / marketing panel
- "Connecting People Through Savings" → **"Saving, made social."** (concrete, less corporate-generic)
- "Save Now. / Grow Together." → **"Save today. / Reach it together."** (keeps the two-beat; avoids the vague "grow" money claim — see Compliance)
- "Open a non-custodial wallet in minutes. No bank account needed — just you, your goals, and your circle." → **"Open a secure wallet in minutes — no bank account needed. Set a goal, save with people you trust."** (one em-dash max; "secure" over the jargon-forward "non-custodial" in the hero; keep "non-custodial" as a trust chip below)
- Trust chips "Non-custodial / On-chain verified / Trusted circles" → **"You hold the keys / Verified on Base / Save with people you trust"** (plain-language benefits; "On-chain verified" → what it means for them)

### Auth panel
- "Continue with Privy" → **"Continue with email or phone"** (users don't know "Privy"; name the benefit/method)
- "Sign in with passkey" → keep, good. "Sign in with Face ID, Touch ID, or a security key" → keep, good.
- "Passkey sign-in was cancelled." → **"Sign-in cancelled."** "Could not sign in with passkey." → **"We couldn't sign you in. Please try again."**
- "Could not sign out" / "Please try again." → **"Couldn't sign out" / "Please try again."**

### Dashboard
- "Welcome back" → keep (add first name when available: "Welcome back, Jay").
- "Coming up" → **"Up next"** (tighter). "Keep learning" → **"Keep learning"** (fine).
- "No goals yet — create your first one." → **"No goals yet. Create your first one."**
- "No active circles yet." → keep. "No activity yet." → keep.
- "Understanding Blockchain (Simply)" (lesson card) → **"Blockchain, explained simply"** (see lessons below)

### Goals (list + create)
- "Create a savings goal" / "Create a goal" (two variants) → standardize: heading **"Create a goal"**, button **"Create goal"**.
- Labels → sentence case: "Goal Name" → **"Goal name"**; "Target Amount (USDC)" → **"Target amount (USDC)"**; "Target Date" → **"Target date"**; "Contribution frequency" → keep (already sentence case).
- Placeholder "Emergency Fund" → **"e.g. Emergency fund"**; "Family Savings" → **"e.g. Family savings"** (signal it's an example).
- "Loading goals..." → **"Loading your goals…"** (use a real ellipsis character).

### Goal detail
- "Add to this goal" → **"Add money"**; "Withdraw from this goal" → **"Withdraw"** (verb-first, shorter).
- "Contribution plan" → keep. "On-chain vault" → **"On-chain vault"** (fine; add a one-line plain explainer: "Your savings are held in a vault only you can withdraw from.")
- "Delete goal" → keep. "Goal not found" → **"We couldn't find that goal."**

### Circles (list + create)
- "Create new Susu Circle" → **"Create a circle"** (define Susu once in a subtitle: "A Susu is a savings circle — members contribute each round and take turns receiving the pot.")
- "Start a new circle" → align to **"Create a circle"** (don't use two verbs for one action).
- Labels → sentence case: "Circle type" (fine); "Each person pays per round (USDC)" → **"Contribution per round (USDC)"**; "Number of rounds" (fine); "Member Emails (comma separated)" → **"Member emails"** with helper text "Separate emails with commas."
- "How a Susu works:" → **"How a circle works"** (no trailing colon on a heading).
- "You pay / round" → **"You pay per round"**; "You receive" → keep.
- "Forming — waiting to start" → **"Forming. Waiting to start."** (or a status chip: "Forming").
- Placeholder "friend@example.com, cousin@example.com" → **"friend@email.com, cousin@email.com"** (consistent example domain).

### Circle detail
- "Circle is still forming" / "Circle is still forming" → **"This circle hasn't started yet."**
- "Build your circle" → keep (good). "Round progress" → keep. "On-chain escrow" → add plain explainer: "Contributions are held in an on-chain escrow until each round pays out."
- "Your contributions" → keep. "Circle not found" → **"We couldn't find that circle."**
- This screen has 5 em-dashes — replace each connector dash with a period or comma.

### Wallet
- "Deposit USDC on-chain" → **"Add USDC"** (verb-first; "on-chain" is implied). "Send USDC to any Base address" → **"Send USDC to any Base wallet address"** (clarity).
- Placeholder "Recipient Base address (0x…)" → keep (good). "0.00" / "100" placeholders → keep.
- "Local currency (GHS · NGN) is coming soon." → **"Local currency (GHS, NGN) is coming soon."** (comma over the middot for plain text).
- "Built on Base" → keep (trust signal).

### Learn / lessons
- "Keep your streak going — one lesson at a time." → **"Keep your streak going."** (cut filler)
- "Loading lessons..." → **"Loading lessons…"**; "No lessons available." → keep.
- "Understanding Blockchain (Simply)" → **"Blockchain, explained simply"**; "Understanding USDC" → **"What is USDC?"**; "What is a Susu?" → keep (good); "Setting Savings Goals That Stick" → **"Savings goals that actually stick"**; "Sending Money Internationally" → **"Sending money abroad"**; "Building Your Emergency Fund" → **"Building an emergency fund"**.
- "Key takeaways" → keep (good).

### Activity
- "Upcoming reminders" → keep. "Transaction history" → keep. "No transactions yet." → keep. "Loading activity..." → **"Loading activity…"**

### Notifications
- "You're all caught up." → keep (genuinely good, human).

### Profile
- "Choose light, dark, or match your device" → keep (good, plain).
- "Uploading picture…" → keep. "Yield APY" → see Compliance (qualify it).

### Not found
- "404 Page Not Found" → **"Page not found"** + a line: "The page you're looking for doesn't exist or moved." + a "Back to dashboard" button.

---

## Backend — notifications & emails (high impact; users see these most)

**Remove all emojis from money notifications. Calm, specific, past-tense.**
- "You received the pot! 🎉" / body "{amt} from \"{circle}\" landed in your wallet." → title **"You received the pot"**, body **"{amt} from {circle} is now in your available balance."**
- "Your savings are back! 🎉" / "{amt} from \"{circle}\" landed in your wallet." → title **"Your savings are back"**, body **"{amt} from {circle} is now in your available balance."**
- "USDC received" / "{amt} is now in your wallet." → keep title; body **"{amt} was added to your wallet."**
- "{amt} arrived in your wallet." → **"{amt} was added to your wallet."**
- "Withdrawal sent" / "{amt} sent to {addr}." → keep (good, calm).
- "Contributed to {circle}" / "You paid {amt} for round {round}." → **"Contribution confirmed" / "You contributed {amt} to {circle}, round {round}."**
- "Added to {goal}" / "{amt} {emoji} moved into your {goal} goal." → **"Added to {goal}" / "{amt} moved into {goal}."** (drop the emoji interpolation)
- "Circle started" / "\"{circle}\" is now active — round 1 has begun." → **"Circle started" / "{circle} is now active. Round 1 has begun."**
- "New circle member" / "{name} joined \"{circle}\"." → keep (good).
- "Circle invitation" / "{inviter} invited you to join \"{circle}\"." → keep (good).

**Email**
- Subject "{inviter} invited you to a Susu circle on MoolaHub" → **"{inviter} invited you to a savings circle on MoolaHub"** ("Susu" may be unfamiliar in an inbox; define it in the body).
- Heading "Join \"{circle}\"" → keep.

**Quote style:** stop wrapping circle/goal names in straight quotes in notifications; it reads robotic. Use the name plainly (the UI can bold it).

---

## Lessons content (lessons-data.ts)
The educational copy is solid and human; only the titles need the de-AI pass above. In the bodies, trim a few textbook openers ("Imagine 10 friends each contribute…") only if you want a snappier read — optional, low priority. Keep the substance.

---

## Compliance flags (financial-services copy — get Legal's eyes)
- **"Grow your money" / "Grow Together" / "grow your money with circles"** — implies returns. Reframe around *saving* and *reaching goals*, not growth, unless you can substantiate it. ("Save toward your goals, together.")
- **"Yield APY"** — if you display a yield figure, it needs a rate source, "variable," and a disclosure. Don't show a bare APY number without context. (Flag for Legal before launch.)
- **"On-chain verified"** — fine as a fact; avoid implying it guarantees safety of funds.
- **"Non-custodial / You hold the keys"** — accurate and good; pair with a note that the user is responsible for their recovery method.
- No superlatives found ("best/fastest/only") — good, keep it that way.

---

## How to apply
These are pure string changes (no logic). Two clean ways:
1. **Hand to Replit/devs** as this doc — every change is before→after with a location. Pair with the global style rules so the rest of the app's strings get the same treatment.
2. **I can stage the edits** across the page components + `lib/circles.ts`/`goals.ts`/`deposits.ts` notification strings + `lessons-data.ts` titles, delivered as an overlay you push (same flow as the other work), then `pnpm run typecheck`.

Adopt the style rules in a short `BRAND_VOICE.md` so new copy stays consistent and never drifts back to the AI-default voice.

