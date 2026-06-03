---
name: Monorepo composite tsconfig
description: TS project-reference requirement when adding a new shared lib to the pnpm monorepo.
---

# Rule
- Any `lib/*` package that is consumed via a TypeScript project reference (listed in another package's `tsconfig.json` `references`) must set `"composite": true` in its own `tsconfig.json`. Match the sibling libs: also set `declarationMap: true`, `emitDeclarationOnly: true`, `outDir: "dist"`, `rootDir: "src"`.
- **Why:** `tsc --build` fails with `error TS6306: Referenced project ... must have setting "composite": true.` Newly scaffolded libs (e.g. an object-storage-web lib) sometimes ship without it.
- **How to apply:** when a workspace typecheck fails with TS6306, add `composite: true` to the named lib's tsconfig.
