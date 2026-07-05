---
name: MoolaHub typography system
description: The intentional font stack (why these faces) and the Space Grotesk 700 weight-cap gotcha.
---

# MoolaHub typography system

Type stack (CSS vars in `src/index.css`, loaded via Google Fonts `<link>` in `index.html`):
- **Display** (`--app-font-display`, `.font-display`): **Space Grotesk**
- **Body** (`--app-font-sans`, default): **Hanken Grotesk**
- **Mono** (`--app-font-mono`, eyebrows/labels): **IBM Plex Mono**

**Why:** Replaced the original Inter (body) + Poppins (display) — the two loudest "AI-generated
default" typefaces — to make the app read as professionally designed. Chose an engineered grotesk
system (Space Grotesk is technical/distinctive with strong numerals; Hanken Grotesk is a legible
humanist grotesk) that deepens the existing jade/"Built on Monad" fintech identity rather than
reinventing it. Do not revert to Inter/Poppins.

**How to apply / gotchas:**
- **Space Grotesk maxes at 700.** Never use `font-extrabold` (800) on a `.font-display` element —
  the browser synthesizes faux-bold (smeared strokes), which is exactly the amateur tell we removed.
  Use `font-bold`. The Google Fonts request only asks up to 700 for Space Grotesk anyway.
- `.font-display` has a base-layer rule adding `letter-spacing: -0.018em` + `font-variant-numeric:
  tabular-nums lining-nums` so money headings/figures stay optically aligned; per-element
  `tracking-*` and `tabular-nums` utilities still override it (utilities layer wins in Tailwind v4).
- **Canvas text mirrors this stack manually.** Any `ctx.font` string (e.g. `StreakShareCard.tsx`)
  must use `'Space Grotesk'`/`'Hanken Grotesk'`, not Inter — canvas won't inherit CSS vars, and
  Inter is no longer loaded so it would silently fall back to system-ui.
