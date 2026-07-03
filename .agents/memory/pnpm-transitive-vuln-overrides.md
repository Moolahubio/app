---
name: pnpm transitive-vuln overrides
description: How to fix flagged transitive dependency CVEs in this monorepo without breaking healthy copies
---

# Fixing transitive dependency vulnerabilities (pnpm monorepo)

All deps flagged by the security audit here are **transitive** (pulled in by
@google-cloud/storage, @solana/web3.js, gaxios, jayson, viem, privy, tsx, etc.).
Fix them with `pnpm.overrides` in the **root** `package.json`.

**Use version-TARGETED override keys, not blanket package names.**
- `"uuid@8.3.2": "11.1.1"` only rewrites the vulnerable copy.
- `"uuid": "11.1.1"` would also drag down healthy newer copies already in the
  tree (e.g. uuid@14 from rpc-websockets, esbuild@0.27 from the api-server build,
  ws@8.21/ws@7.5.11 that jayson legitimately pins to ^7) — a regression, and ws7
  consumers can break.

**Why:** the tree intentionally contains multiple major versions of ws/uuid/
esbuild. A blanket override collapses them all to one version and can downgrade
or break the ones that were never vulnerable.

**How to apply:**
1. `runDependencyAudit()` (security_scan skill) gives the authoritative `fix.version`.
2. Add `"<pkg>@<badversion>": "<fixversion>"` per flagged entry; prefer a fix
   version already present in the tree to avoid new downloads.
3. `pnpm install`, then confirm with `runDependencyAudit()` (expect 0) and that
   the lockfile no longer lists the bad versions (an `overrides:` echo block near
   the lock top is normal/expected).
4. Restart the api-server workflow — its `build.mjs` runs esbuild, so an esbuild
   override is exercised at build time; verify it still boots + circles e2e passes.

Note: a couple of pre-existing peer warnings (esbuild-plugin-pino wanting esbuild
<=0.25.8 vs the api-server's own esbuild@0.27, and jayson's isomorphic-ws/ws@7)
are unrelated to the overrides and non-fatal.

## The pnpm-workspace.yaml `overrides:` block is INERT here
`package.json` `pnpm.overrides` is the ONLY effective override source. pnpm uses a
single overrides source, and when `package.json` defines `pnpm.overrides`, the
`overrides:` block in `pnpm-workspace.yaml` is fully ignored. Evidence: the
lockfile's top `overrides:` echo lists only the package.json keys; the workspace
block's `esbuild: "<ver>"` blanket never collapsed transitive esbuild (0.27.7 from
tsx/@orval/core survived it), its `@esbuild/*: "-"` platform exclusions did not
strip those binaries, and its `@esbuild-kit/esm-loader: npm:tsx` remap didn't take.
**How to apply:** put EVERY override (version bumps, platform "-", aliases) in
root `package.json` `pnpm.overrides`. Do not add or edit entries in the
pnpm-workspace.yaml `overrides:` block expecting them to work — they won't until
that block is consolidated into package.json.

**Catalog-pinned deps (`pnpm-workspace.yaml` `catalog:`) need the catalog entry
bumped too, not just `pnpm.overrides`.** For vite (consumed via `catalog:` by
both apps and required as an exact peer by @tailwindcss/vite / @vitejs/plugin-react),
a `"vite@7.3.3": "7.3.5"` override alone did not propagate — the peer-resolved
copies stayed pinned at 7.3.3 until the catalog line itself (`vite: ^7.3.2`) was
bumped to `^7.3.5`. Do both for any catalog-managed package: the override as a
safety net, and the catalog range bump as the actual fix.

Python (uv, not pnpm): there's no `pnpm.overrides` equivalent. Use either
`[tool.uv] constraint-dependencies` (raises the minimum for transitive deps
without adding a direct dependency) or `override-dependencies` (forces the exact
version, ignoring what the package declares) in `pyproject.toml`, then `uv sync`.
Prefer `constraint-dependencies` when the package is already pulled in
transitively and you just need to bump its floor.
