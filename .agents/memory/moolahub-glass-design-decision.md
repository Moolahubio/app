---
name: MoolaHub liquid-glass design decision
description: The canonical MoolaHub web UI is the "de-AI"/taste-upgrade design, NOT a wholesale glass restructure. How to add glass.
---

# MoolaHub liquid-glass design decision

The user's preferred moolahub-app web UI is the original "taste-upgrade / de-AI" design (its layouts, spacing, and page structure). A full wholesale "liquid-glass refresh" that restructured every page (new primitives like GlassCard/MetricCard, gradient buttons, a parallel --mh-* token system) was built once and then **reverted by the user**.

**Why:** the user liked the existing layouts; they wanted the glass *aesthetic* and hover feedback, not a redesign.

**How to apply glass/hover going forward:**
- Apply it at the SHARED-component level so it flows everywhere without touching page layouts: base `Card`, `Button`, `EmptyState`, and the app shell (`app-layout.tsx`).
- The design system ALREADY ships the primitives in `src/index.css`: `.glass`, `.glass-dark`, `.hover-lift`, `.focus-ring`, plus reduced-transparency / no-backdrop-filter / reduced-motion fallbacks. Reuse these — do NOT invent a new token system.
- `.glass` sets `border/background/box-shadow` in the `@layer components` layer, so Tailwind border utilities (`border-y-0`, `border-s-0`, `border-x-0`) in the utilities layer still win and can strip specific sides (the shell keeps only its divider border this way).
- Caveat: `.glass` uses `backdrop-filter`, which creates a containing block for descendant `position:fixed` and a new stacking context. Fine because overlays/menus are portaled to `<body>`; if you ever render a non-portaled fixed element inside a `Card`, it will anchor to the card, not the viewport.

**Glass must NOT shift surface color.** The user rejected a first pass where `.glass` used a white/dark tinted gradient + `backdrop-filter: ... saturate(160%)`; the saturate amplified the app's green background bleeding through and visibly changed card color in BOTH light and dark mode.
**Why:** they wanted the frosted/translucent *effect* + hover only, with the surface reading as its original `--card` color.
**How to apply:** base `.glass` background on `hsl(var(--card) / <alpha>)` and its border on `hsl(var(--card-border))`; use `backdrop-filter: blur(...)` WITHOUT `saturate()`. Never introduce a saturate() or an arbitrary white/ink tint that departs from the card token.

**Light mode needs near-opaque glass.** In light mode `--card` is pure white (`0 0% 100%`) but `--background` is *mist* (`135 15% 97%`, faintly green). So a translucent white card lets the green mist bleed through and stops reading as the crisp white production cards. Fix: light `.glass` uses `hsl(var(--card) / 0.96)` (near-opaque) + the original `--shadow-card` values, NO inset highlight — so content cards match production exactly; the `blur` still frosts the sticky header/nav/sidebar where content scrolls beneath. Dark mode `--card` (ink-900) sits on an even-darker `--background`, so it tolerates a lower-alpha gradient (~0.72–0.86) without a visible color shift; keep the two modes tuned independently (edit base `.glass` for light, `.dark .glass` for dark).

Do not re-propose the wholesale restructure unless the user explicitly asks for a redesign.
