import { db } from "@/lib/db";
import { createWalletForUser } from "@/lib/server/wallet";
import { acct, transfer } from "@/lib/server/ledger";

/** Wipe all tables between tests. Destructive — intended for a test database. */
export async function resetDb() {
  await db.$executeRawUnsafe(
    `TRUNCATE "Posting","Transaction","LedgerAccount","Contribution","CircleInvite","CircleMember","Circle","Goal","LessonProgress","Notification","Session","Wallet","User" RESTART IDENTITY CASCADE;`,
  );
}

let n = 0;
export async function createTestUser(name = "Test User", kyc = "verified") {
  n += 1;
  const email = `user${n}.${Date.now()}@test.local`;
  const user = await db.user.create({
    data: { name, email, passwordHash: null, kycStatus: kyc },
  });
  await createWalletForUser(user.id);
  return user;
}

/** Credit a user's available balance directly (bypasses KYC/on-chain). */
export async function fund(userId: string, cents: number) {
  await transfer({
    type: "deposit",
    description: "Test funding",
    userId,
    fromKey: acct.external,
    toKey: acct.wallet(userId),
    amountCents: cents,
  });
}

/** Create an active circle with the given members already in the rotation. */
export async function makeActiveCircle(
  members: { id: string }[],
  contributionCents: number,
) {
  const circle = await db.circle.create({
    data: {
      name: "Test Circle",
      status: "active",
      contributionCents,
      frequency: "weekly",
      totalRounds: members.length,
      currentRound: 1,
      startDate: new Date(),
      createdById: members[0].id,
      members: {
        create: members.map((m, i) => ({
          userId: m.id,
          position: i + 1,
          payoutRound: i + 1,
        })),
      },
    },
  });
  return circle;
}

