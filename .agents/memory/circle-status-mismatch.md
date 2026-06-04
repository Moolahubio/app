---
name: Circle status/state frontend-backend mismatch
description: MoolaHub circle-detail page checks status/member-state values the backend never emits
---

The MoolaHub circles backend and the circle-detail frontend disagree on enum values, so the detail page's setup/start UI silently never renders.

- Backend circle `status` for a not-yet-started circle is `"forming"` (schema default in `lib/db/src/schema/circles.ts`), and uses `"active"` / `"completed"`. There is no `"pending"`.
- Backend member states (from `memberState` in `artifacts/api-server/src/lib/circles.ts`) are `paid` / `current` / `upcoming`. There is no `"accepted"`.
- But `artifacts/moolahub-app/src/pages/circle-detail.tsx` checks `circle.status === "pending"` (→ `isPending`) and `m.state === "accepted"` (→ `allAccepted`). Both are always false, so the invite form and "Start circle" button never appear on that page.

**Why:** Pre-existing bug, discovered during the rotation/accumulation circle-type work; left untouched to keep that task in scope. Filed as a follow-up task.

**How to apply:** When touching circle setup/start UX, align the frontend checks to the real backend enums (`forming`, and `paid/current/upcoming`) rather than trusting the existing string literals. Don't assume the detail-page start flow works today.
