---
name: Fixed overlays break under backdrop-filter ancestors
description: Why `position: fixed` click-catchers and modals misbehave in the moolahub-app shell, and the click-outside pattern to use instead.
---

# `fixed inset-0` is NOT viewport-relative inside the app shell

The moolahub-app `<header>` (in `app-layout.tsx`) uses `backdrop-blur-sm`
(`backdrop-filter`). Any element with `backdrop-filter` (or `filter`, `transform`,
`perspective`, `contain`, `will-change` of those) establishes a **containing block for
fixed-position descendants**. So a `position: fixed; inset: 0` element rendered anywhere
inside that header resolves against the header's box, not the viewport — it only covers the
header strip.

**Symptom seen:** the NotificationBell used a `fixed inset-0` overlay as a click-outside
catcher. Because the bell lives in the blurred header, the overlay covered only the header,
so clicking anywhere in the main content never closed the dropdown.

**Why it matters:** any future dropdown/popover/modal mounted within a `backdrop-filter`
(or `filter`/`transform`) ancestor will have the same trap — a full-screen overlay won't be
full-screen, and `position: fixed` modals will be clipped/offset.

**How to apply:**
- For click-outside, prefer a `document` `pointerdown` listener gated on an `open` flag with
  a `containerRef.contains(e.target)` check (plus Escape on `keydown`), and clean up both in
  the effect return. This sidesteps stacking/containing-block issues entirely and lets the
  click pass through to the app (no dimming modal needed).
- If you truly need a viewport overlay/modal, render it via a portal to `document.body`
  (outside the blurred ancestor), not inline.
