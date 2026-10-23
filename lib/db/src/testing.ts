import pg from "pg";
import { pool } from "./index";
import { isLocalDatabaseUrl, sslFor } from "./connection";

/**
 * E2E teardown. Test suites only, never app code.
 *
 * Postings are append-only and their foreign keys RESTRICT (migration 0003), so
 * a suite can no longer clean up by deleting users and letting the ledger
 * cascade away. This removes everything a suite created, ledger first, in one
 * transaction:
 *   - every ledger transaction that touches an account of the given users,
 *     their goals or the given circles (and the circles they created), or that
 *     is attributed to those users or circles, with ALL of its postings, so no
 *     half-deleted, unbalanced transaction is left on the shared `external` /
 *     `fees` accounts;
 *   - those ledger accounts;
 *   - the circles, goals and users (their other rows cascade as before).
 *
 * Deleting postings needs the owner-only purge switch the append-only trigger
 * honours. When the suites run as the least-privilege app role (CI), set
 * MIGRATIONS_DATABASE_URL so this connects as the table owner instead.
 */
export async function purgeTestData(ids: {
  userIds?: string[];
  goalIds?: string[];
  circleIds?: string[];
}): Promise<void> {
  const userIds = ids.userIds ?? [];
  const goalIds = ids.goalIds ?? [];
  const circleIds = ids.circleIds ?? [];
  if (!userIds.length && !goalIds.length && !circleIds.length) return;

  const ownerUrl = process.env.MIGRATIONS_DATABASE_URL;
  // The purge switch deletes ledger rows, so refuse anything but a local dev or
  // CI database, whatever the caller's environment claims.
  const target = ownerUrl ?? process.env.DATABASE_URL ?? "";
  if (!isLocalDatabaseUrl(target)) {
    throw new Error("purgeTestData only runs against a local database");
  }
  const client = ownerUrl
    ? new pg.Client({ connectionString: ownerUrl, ssl: sslFor(ownerUrl, process.env.PG_CA_CERT) })
    : await pool.connect();
  if (ownerUrl) await (client as pg.Client).connect();
  try {
    await client.query("BEGIN");
    await client.query("SET LOCAL moolahub.ledger_purge = 'on'");
    const circles = await client.query<{ id: string }>(
      "SELECT id FROM circles WHERE id = ANY($1::uuid[]) OR created_by_id = ANY($2::uuid[])",
      [circleIds, userIds],
    );
    const goals = await client.query<{ id: string }>(
      "SELECT id FROM goals WHERE id = ANY($1::uuid[]) OR user_id = ANY($2::uuid[])",
      [goalIds, userIds],
    );
    const allCircles = circles.rows.map((r) => r.id);
    const allGoals = goals.rows.map((r) => r.id);
    const accounts = await client.query<{ id: string }>(
      `SELECT id FROM ledger_accounts
        WHERE user_id = ANY($1::uuid[]) OR goal_id = ANY($2::uuid[]) OR circle_id = ANY($3::uuid[])`,
      [userIds, allGoals, allCircles],
    );
    const accountIds = accounts.rows.map((r) => r.id);
    const txns = await client.query<{ id: string }>(
      `SELECT DISTINCT transaction_id AS id FROM postings WHERE account_id = ANY($1::uuid[])
       UNION
       SELECT id FROM transactions WHERE user_id = ANY($2::uuid[]) OR circle_id = ANY($3::uuid[])`,
      [accountIds, userIds, allCircles],
    );
    const txnIds = txns.rows.map((r) => r.id);
    await client.query("DELETE FROM postings WHERE transaction_id = ANY($1::uuid[])", [txnIds]);
    await client.query("DELETE FROM transactions WHERE id = ANY($1::uuid[])", [txnIds]);
    await client.query("DELETE FROM ledger_accounts WHERE id = ANY($1::uuid[])", [accountIds]);
    await client.query("DELETE FROM circles WHERE id = ANY($1::uuid[])", [allCircles]);
    await client.query("DELETE FROM goals WHERE id = ANY($1::uuid[])", [allGoals]);
    await client.query("DELETE FROM users WHERE id = ANY($1::uuid[])", [userIds]);
    await client.query("COMMIT");
  } catch (e) {
    await client.query("ROLLBACK").catch(() => {});
    throw e;
  } finally {
    if (ownerUrl) await (client as pg.Client).end();
    else (client as pg.PoolClient).release();
  }
}
