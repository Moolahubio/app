import { randomUUID } from "node:crypto";

/**
 * Focused checks for the 2FA hardening:
 *  1. A challenge is single-use even under a concurrent race (exactly one of two
 *     simultaneous consume calls returns the row).
 *  2. An expired challenge is never consumable.
 *  3. Backup codes are single-use (consume removes exactly the used hash).
 */

async function run() {
  const { db, usersTable, twoFactorChallengesTable } = await import("@workspace/db");
  const { eq } = await import("drizzle-orm");
  const {
    createTwoFactorChallenge,
    consumeTwoFactorChallenge,
    generateBackupCodes,
    consumeBackupCode,
  } = await import("./twofactor");

  const runId = randomUUID().slice(0, 8);
  const [user] = await db
    .insert(usersTable)
    .values({ name: `2FA ${runId}`, email: `e2e+2fa+${runId}@moolahub.test` })
    .returning();

  const createdIds: string[] = [];
  try {
    // 1) Concurrency: two simultaneous consumes, exactly one wins.
    const challengeId = await createTwoFactorChallenge(user.id, true);
    createdIds.push(challengeId);
    const [a, b] = await Promise.all([
      consumeTwoFactorChallenge(challengeId),
      consumeTwoFactorChallenge(challengeId),
    ]);
    const winners = [a, b].filter((r) => r !== null);
    if (winners.length !== 1) {
      throw new Error(`expected exactly one winner, got ${winners.length}`);
    }
    if (winners[0]!.userId !== user.id || winners[0]!.rememberMe !== true) {
      throw new Error("consumed challenge returned wrong fields");
    }
    const after = await db
      .select()
      .from(twoFactorChallengesTable)
      .where(eq(twoFactorChallengesTable.id, challengeId));
    if (after.length !== 0) throw new Error("challenge row not deleted after consume");

    // 2) Expired challenge is not consumable.
    const [expired] = await db
      .insert(twoFactorChallengesTable)
      .values({ userId: user.id, rememberMe: false, expiresAt: new Date(Date.now() - 1000) })
      .returning();
    createdIds.push(expired.id);
    const expiredResult = await consumeTwoFactorChallenge(expired.id);
    if (expiredResult !== null) throw new Error("expired challenge was consumed");

    // 3) Backup codes single-use.
    const { codes, hashes } = generateBackupCodes();
    const remaining = consumeBackupCode(codes[0], hashes);
    if (!remaining || remaining.length !== hashes.length - 1) {
      throw new Error("backup code consume did not remove exactly one hash");
    }
    const reuse = consumeBackupCode(codes[0], remaining);
    if (reuse !== null) throw new Error("backup code was reusable");

    console.log(`\u2713 2FA hardening e2e passed (runId=${runId})`);
  } finally {
    for (const id of createdIds) {
      await db.delete(twoFactorChallengesTable).where(eq(twoFactorChallengesTable.id, id));
    }
    await db.delete(usersTable).where(eq(usersTable.id, user.id));
  }
}

run()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("\u2717 2FA hardening e2e FAILED");
    console.error(err);
    process.exit(1);
  });
