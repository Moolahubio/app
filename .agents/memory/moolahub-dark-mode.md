---
name: MoolaHub dark-mode pitfalls
description: Recurring dark-mode contrast traps in the MoolaHub web app and how to avoid them
---

# MoolaHub dark-mode pitfalls

Two classes of dark-mode bugs recur in this app:

1. **Theme-blind brand assets.** The horizontal logo ships as two SVGs: an "ink"
   variant (near-black `#0C1512` wordmark) for light backgrounds and a "light"
   variant (white wordmark) for dark backgrounds. The `Logo`/`MoolaMark`
   components resolve the variant from `useTheme().resolvedTheme` when no explicit
   `tone` prop is passed, falling back to the prop when given (the login brand
   panel is always-dark and forces `tone="light"`).
   **Why:** previously the ink logo rendered on the dark sidebar and vanished.
   **How to apply:** never hardcode a single logo asset for a surface that flips
   theme; let it be theme-aware or pass the correct explicit tone.

2. **Light `bg-*-50` surfaces with no dark variant.** Mint cards/selectors using
   `bg-jade-50` keep their pale background in dark mode while `text-foreground`
   flips to light → light-on-light wash-out. Pattern used to fix: add
   `dark:bg-jade-500/10` (+ `dark:border-jade-500/20` where bordered).
   **How to apply:** any tinted light-shade background (`bg-*-50/100`) needs a
   `dark:` counterpart, or use semantic tokens that already adapt.
