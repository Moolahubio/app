---
name: MoolaHub i18n plural parity
description: How to audit locale key parity without breaking Arabic (and other) CLDR pluralization.
---

# i18n key-parity audits must be plural-suffix-aware

When checking that every locale namespace has the same keys as `en`, compare **base** keys only: strip trailing CLDR plural suffixes (`_zero`/`_one`/`_two`/`_few`/`_many`/`_other`) before diffing.

**Why:** A naive exact-key-set audit flags Arabic as having "extra" keys, because Arabic legitimately needs `_zero/_two/_few/_many` where English only has `_one/_other`. A prior session deleted those correct Arabic forms just to make a naive audit pass — i18next then fell back to `_other` and rendered grammatically wrong plurals (e.g. "٣ يوم" instead of "٣ أيام"). Stripping correct grammar to satisfy a tool is backwards.

**How to apply:**
- Normalize keys by removing the plural suffix, then require each locale's base-key set to equal `en`'s. Extra CLDR categories in a locale are correct, not errors.
- Every pluralized family must still have `_other` in every locale (i18next's fallback).
- Only `streak` currently defines plural families (`unit.*`, `badges.quartersKept`, `badges.progressDays`); Arabic carries the full 6-category expansion there.
- Non-plural keys used with `count` (e.g. `freezes.available`, `vacation.startDays`) are fine as a single base key — i18next uses the base when no suffixed forms exist.
