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
