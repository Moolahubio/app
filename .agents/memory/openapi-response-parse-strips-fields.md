---
name: API responses are filtered by the OpenAPI/zod schema
description: Fields a route handler returns are silently dropped if not declared in the OpenAPI response schema
---

In this monorepo, route handlers serialize responses through generated zod schemas (e.g. `GetCircleResponse.parse(payload)` in `artifacts/api-server/src/routes`). zod's object parse **strips unknown keys by default**, and the zod/TypeScript clients are generated from `lib/api-spec/openapi.yaml`.

Consequence: a field the backend computes and returns will **silently never reach the frontend** unless it is also declared in the corresponding response schema in `openapi.yaml` (then regenerate with `pnpm --filter @workspace/api-spec run codegen`).

**Why:** Cost real debugging time — backend `getCircleDetail` was returning capability flags (`canStart`, `canInvite`, etc.) that the UI needed, but they were absent from the client because they weren't in the spec; `.parse()` dropped them.

**How to apply:** When the frontend "can't see" a field the backend clearly returns, check the OpenAPI response schema first — don't assume the handler return type is the wire contract. Prefer server-provided capability flags over re-deriving UI gating from raw status/state enums on the client (avoids enum drift).
