---
name: MoolaHub dark-mode contrast
description: Recurring dark-mode readability gotchas in the moolahub-app web UI and how to avoid them.
---

# MoolaHub dark-mode readability

Two recurring sources of low-contrast text in dark mode, both fixed but easy to reintroduce:

1. **Light jade callout cards need an explicit `dark:` background.** Cards styled
   `bg-jade-50/40|50|60` (info callouts, selected radio cards, current-member
   highlights) render as washed-out *light* translucent panels over the dark
   page, killing contrast with their `text-foreground`/`text-muted-foreground`
   text. Always pair them with `dark:bg-jade-500/10` (or `/15` for
   selected/active state).
   **Why:** `bg-jade-50` is near-white; at any opacity over the near-black dark
   bg it stays light. **How to apply:** any new jade-tinted callout/selected
   surface must carry a `dark:` background variant.

2. **Intentionally-dark hero/shell cards (ink-950, same in both themes) used
   too-dim white tiers.** Eyebrow mono labels and helper copy at
   `text-white/40|45|50` are hard to read. Baseline tiers now: eyebrows ≥
   `/55–/60`, helper text ≥ `/65–/70`. Don't drop below `/55` on these cards.

Also: the dark `--muted-foreground` token (in `src/index.css` `.dark` block)
governs most muted subtitles/helper text app-wide; it was lifted to a lighter,
slightly jade-tinted value. Bumping that token is the single biggest dark-mode
readability lever — prefer it over per-element overrides.
