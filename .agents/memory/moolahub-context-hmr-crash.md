---
name: React context + i18n HMR crash
description: Why a context Provider colocated with createContext/hook in a file that imports i18n crashes on locale-JSON edits, and the fix.
---

Editing a locale JSON file (or any HMR cascade through `@/i18n`) crashed the app
with `useLanguage must be used within a LanguageProvider`, even though the
provider tree in App.tsx was correct.

**Root cause:** `use-language.tsx` colocated `createContext`, the `useLanguage`
hook, AND the `LanguageProvider` component in one module that also imports
`@/i18n`. Editing locale JSON invalidates `@/i18n`, which cascades into that
module and RE-RUNS `createContext`, minting a brand-new context object. Existing
mounted consumers still hold the old context, so `useContext` returns null and
the hook throws. React Fast Refresh also refuses the module ("Could not Fast
Refresh: export is incompatible") because it mixes a component export with
non-component exports, which is what turns the invalidation into a full
re-execution.

**Fix / rule:** Put `createContext` + the `useXxx` hook (and its value type) in
their own module that has NO runtime dependency on i18n/resources (type-only
imports are fine — they're erased). Leave the Provider component in a separate,
component-only file that imports the context from the stable module.

**Why:** The context identity must be stable across HMR. If the module that
calls `createContext` can be invalidated by resource edits, consumers desync.
Keeping context in an i18n-free module guarantees the identity survives, and
making the provider file component-only lets Fast Refresh re-render it in place.

**How to apply:** Whenever a React context Provider lives in the same file as
`createContext`/its hook AND that file (directly or transitively) imports
frequently-edited resources (i18n JSON, theme tokens, etc.), split the context +
hook into a resource-free module before shipping. Applies to any future context
in this app (theme, auth, wallet) with the same shape.
