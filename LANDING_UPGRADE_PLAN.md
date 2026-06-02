# MoolaHub — Landing Page Upgrade Plan (`moolahub.io`)

**Goal:** evolve the existing marketing site at `moolahub.io` using the design
direction validated in this repo's `/preview` route — without throwing away the
current site. This is a **plan**, scoped to be executed in the
[`Moolahubio/Website`](https://github.com/Moolahubio/Website) repo.

> Priority note: the product app (`app.moolahub.io`, this repo) ships first.
> This landing upgrade is the follow-on.

---

## 1. What stays (already correct on the brand)

The Website repo's `src/content/brand.ts` is already aligned with our decisions —
keep it as the single source of truth:

- `valueProposition: "Save Now. Grow Together."` ✅ (the corrected tagline)
- `tagline: "Connecting People Through Savings"` ✅
- Logo assets in `public/brand/` and the `Logo` component ✅

No brand contradictions to fix. (The old static brand sheet still shows
"Save Alone…" in its footer — that artwork should be regenerated, but the code
is right.)

## 2. Design direction (validated in `/preview`)

The `/preview` route in this repo demonstrates the target look, reusing the
official brand: dark **ink** hero with a subtle grid + jade glow, the
**ascending-chart motif**, **IBM Plex Mono eyebrow labels**, jade CTAs, and a
clean light body. Port the *system*, not pixel-for-pixel markup.

## 3. Section-by-section upgrade

| # | Section | Upgrade |
| --- | --- | --- |
| 1 | **Hero** | Ink background + grid + jade glow; H1 "Save Now. Grow Together."; primary CTA → `app.moolahub.io/login`; live "total saved" + ascending-chart visual; `Built on Base` eyebrow. |
| 2 | **Trust strip** | "Powered by" row using the real `public/partners/` marks (Privy · Base · USDC) + `GHS · NGN · USDC`. |
| 3 | **Pillars** | Four cards: Susu Circles · Savings Goals · Learn · Verified on-chain. |
| 4 | **How a Susu works** | Explain rotating savings + the audited-contract replacement for the human collector; animated circle/rotation visual. |
| 5 | **Goals** | "Name it, automate it, reach it"; reinforce *goals are allocations over one wallet*, not separate accounts. |
| 6 | **Learn** | Surface real lessons (financial empowerment as a first-class feature), linking into `app.moolahub.io/learn`. |
| 7 | **Blockchain verification** | "Don't trust us. Verify it." — non-custodial, audited contracts (mainnet **audit-gated**), sample ledger receipt with a `txHash`. |
| 8 | **Trust features** | Payment reminders · payout schedules · contribution history. |
| 9 | **Final CTA + footer** | Repeat tagline; CTA → app; footer with legal/compliance/KYC links. |

## 4. Cross-cutting

- **CTAs point to the app.** Every primary CTA → `https://app.moolahub.io/login`.
- **Conversion:** add a sticky header CTA; lead with one clear primary action per
  viewport.
- **SEO/OG:** per-page `<title>`/description, OpenGraph image using the dark hero,
  JSON-LD `Organization`.
- **Performance:** keep the hero LCP image/SVG inlined; lazy-load below-the-fold;
  target Lighthouse ≥ 95.
- **A11y:** WCAG AA contrast (jade-on-ink passes for large text/UI; use
  `jade-400`/white for body on ink), focus-visible rings, semantic landmarks.
- **Responsive:** mobile-first; stack the hero, collapse nav to a sheet.
- **Theming:** the Website already has a `ThemeProvider` — keep light/dark and use
  the matching logo variant (mark stays jade in both).

## 5. Phased rollout

- **Phase 1 — Hero + nav + CTA wiring** (highest leverage; ship behind a preview URL).
- **Phase 2 — Pillars, Susu explainer, Goals.**
- **Phase 3 — Learn, Verification, Trust features.**
- **Phase 4 — SEO/OG/perf/a11y polish + analytics.**

## 6. Success metrics

- Landing → `app.moolahub.io/login` click-through rate.
- Signup-start conversion from landing.
- Lighthouse (Perf/SEO/Best-practices/A11y) ≥ 95.
- Bounce rate on hero; scroll-depth to the Verification section.

## 7. Reference

The full proposed landing is live in this repo at `/preview`
(`src/app/preview/page.tsx` + `src/components/marketing/*`). It can be ported
into the Website repo's component system as the basis for Phases 1–3.
