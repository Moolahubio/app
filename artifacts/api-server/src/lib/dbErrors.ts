/**
 * Detect a Postgres unique-constraint violation (SQLSTATE 23505).
 *
 * Lets routes treat a DB-enforced uniqueness guarantee (e.g. the
 * case-insensitive username index) as the source of truth: app-level pre-checks
 * are just UX, and a concurrent writer that wins the race surfaces here so it
 * can be mapped to a clean 409 instead of a 500.
 */
export function isUniqueViolation(err: unknown): boolean {
  if (typeof err !== "object" || err === null) return false;
  const code = (err as { code?: unknown }).code;
  if (code === "23505") return true;
  // node-postgres sometimes nests the driver error under `cause`.
  const cause = (err as { cause?: unknown }).cause;
  if (cause && typeof cause === "object" && (cause as { code?: unknown }).code === "23505") return true;
  return false;
}
