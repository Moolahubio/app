/**
 * Seed a realistic, ledger-consistent dataset. Self-contained (no server-only
 * imports) so it runs under tsx. Encryption mirrors src/lib/server/crypto.ts.
 */
import { readFileSync } from "node:fs";
import { createCipheriv, randomBytes, createHash } from "node:crypto";
import { PrismaClient, type Prisma } from "@prisma/client";
import { Keypair } from "@stellar/stellar-sdk";
import bcrypt from "bcryptjs";

// ---- load .env (DATABASE_URL, APP_ENCRYPTION_KEY) ----
try {
  for (const line of readFileSync(".env", "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z_]+)\s*=\s*"?([^"]*)"?\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
  }
} catch {
  /* env may already be present */
}

const db = new PrismaClient();
const DEMO_PASSWORD = "moolahub";

function encKey(): Buffer {
  const raw = process.env.APP_ENCRYPTION_KEY || "dev-insecure-key";
  if (/^[0-9a-fA-F]{64}$/.test(raw)) return Buffer.from(raw, "hex");
  return createHash("sha256").update(raw).digest();
}
function encryptSecret(plain: string): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", encKey(), iv);
  const enc = Buffer.concat([cipher.update(plain, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return `${iv.toString("base64")}.${tag.toString("base64")}.${enc.toString("base64")}`;
}

function acctKey(kind: "wallet" | "goal" | "pool", id: string) {
  return `${kind === "wallet" ? "wallet" : kind === "goal" ? "goal" : "pool"}:${id}`;
}
function describe(key: string) {
  if (key.startsWith("wallet:")) return { key, kind: "available", label: "Wallet", userId: key.slice(7) };
  if (key.startsWith("goal:")) return { key, kind: "goal", label: "Goal allocation", goalId: key.slice(5) };
  if (key.startsWith("pool:")) return { key, kind: "pool", label: "Circle pot", circleId: key.slice(5) };
  if (key === "external") return { key, kind: "external", label: "Fiat rail" };
  if (key === "yield") return { key, kind: "yield", label: "Yield (Blend)" };
  return { key, kind: "fees", label: "Platform fees" };
}
async function ensureAccount(key: string) {
  return db.ledgerAccount.upsert({ where: { key }, update: {}, create: describe(key) as Prisma.LedgerAccountCreateInput });
}
async function transfer(p: {
  type: string;
  description: string;
  userId?: string;
  fromKey: string;
  toKey: string;
  amountCents: number;
  txHash?: string;
  createdAt?: Date;
}) {
  const from = await ensureAccount(p.fromKey);
  const to = await ensureAccount(p.toKey);
  await db.transaction.create({
    data: {
      type: p.type,
      description: p.description,
      userId: p.userId,
      txHash: p.txHash,
      onchainStatus: p.txHash ? "confirmed" : "none",
      createdAt: p.createdAt,
      postings: {
        create: [
          { accountId: from.id, amountCents: -p.amountCents },
          { accountId: to.id, amountCents: p.amountCents },
        ],
      },
    },
  });
}

async function makeUser(name: string, email: string, kyc = "unstarted") {
  const passwordHash = await bcrypt.hash(DEMO_PASSWORD, 10);
  const kp = Keypair.random();
  const user = await db.user.create({
    data: {
      name,
      email,
      passwordHash,
      kycStatus: kyc,
      wallet: {
        create: {
          stellarPublicKey: kp.publicKey(),
          stellarSecretEnc: encryptSecret(kp.secret()),
        },
      },
    },
  });
  return user;
}

function daysAgo(n: number) {
  const d = new Date("2026-06-01T09:00:00Z");
  d.setDate(d.getDate() - n);
  return d;
}

async function main() {
  console.log("Resetting data…");
  await db.posting.deleteMany();
  await db.transaction.deleteMany();
  await db.ledgerAccount.deleteMany();
  await db.contribution.deleteMany();
  await db.circleMember.deleteMany();
  await db.circle.deleteMany();
  await db.goal.deleteMany();
  await db.lessonProgress.deleteMany();
  await db.session.deleteMany();
  await db.wallet.deleteMany();
  await db.user.deleteMany();

  console.log("Creating users…");
  const ama = await makeUser("Ama Mensah", "ama@moolahub.io", "verified");
  const makolaOthers = await Promise.all(
    [
      ["Esi Boateng", "esi@example.com"],
      ["Kofi Asante", "kofi@example.com"],
      ["Yaw Darko", "yaw@example.com"],
      ["Adwoa Owusu", "adwoa@example.com"],
      ["Kwame Nkrumah", "kwame@example.com"],
      ["Akua Sarpong", "akua@example.com"],
      ["Fiifi Tetteh", "fiifi@example.com"],
    ].map(([n, e]) => makeUser(n, e, "verified")),
  );
  const familyOthers = await Promise.all(
    [
      ["Kojo Mensah", "kojo@example.com"],
      ["Abena Mensah", "abena@example.com"],
      ["Nana Mensah", "nana@example.com"],
      ["Efua Mensah", "efua@example.com"],
      ["Kweku Mensah", "kweku@example.com"],
    ].map(([n, e]) => makeUser(n, e, "verified")),
  );
  const techOthers = await Promise.all(
    [
      ["Selorm Agbley", "selorm@example.com"],
      ["Nana Yaa", "nanayaa@example.com"],
    ].map(([n, e]) => makeUser(n, e, "verified")),
  );

  console.log("Funding Ama + goals…");
  await transfer({ type: "deposit", description: "Deposit via Yellowcard", userId: ama.id, fromKey: "external", toKey: acctKey("wallet", ama.id), amountCents: 475230, txHash: "dep3k9a1", createdAt: daysAgo(4) });
  await transfer({ type: "yield", description: "Yield earned · Blend", userId: ama.id, fromKey: "yield", toKey: acctKey("wallet", ama.id), amountCents: 7420, createdAt: daysAgo(0) });

  const goalSeeds = [
    { name: "Rent buffer", emoji: "🏠", targetCents: 200000, save: 164000, auto: 5000, color: "jade", deadlineDays: 61 },
    { name: "New laptop", emoji: "💻", targetCents: 120000, save: 86000, auto: 4000, color: "sky", deadlineDays: 44 },
    { name: "Emergency fund", emoji: "🛟", targetCents: 150000, save: 62000, auto: 3000, color: "amber", deadlineDays: 213 },
  ];
  for (const g of goalSeeds) {
    const deadline = new Date("2026-06-01T00:00:00Z");
    deadline.setDate(deadline.getDate() + g.deadlineDays);
    const goal = await db.goal.create({
      data: { userId: ama.id, name: g.name, emoji: g.emoji, targetCents: g.targetCents, autoSaveCents: g.auto, color: g.color, deadline },
    });
    await transfer({ type: "goal_allocate", description: `Allocation → ${g.name}`, userId: ama.id, fromKey: acctKey("wallet", ama.id), toKey: acctKey("goal", goal.id), amountCents: g.save, createdAt: daysAgo(5) });
  }

  console.log("Creating circles…");
  // ---- Makola Market Circle: weekly, 8 members, round 4 of 8 ----
  const makola = await db.circle.create({
    data: {
      name: "Makola Market Circle",
      status: "active",
      contributionCents: 5000,
      frequency: "weekly",
      totalRounds: 8,
      currentRound: 4,
      startDate: new Date("2026-05-11T00:00:00Z"),
      contractAddress: "CDLZ7Q4SUSU8XK2M9PQRSTUVWXYZ234567ABCDEFGHIJKLMNOPQ",
      createdById: makolaOthers[0].id,
    },
  });
  const makolaMembers = [ama, ...makolaOthers];
  // Ama is position 3 (payout round 3, already received)
  const makolaOrder = [makolaOthers[0], makolaOthers[1], ama, makolaOthers[2], makolaOthers[3], makolaOthers[4], makolaOthers[5], makolaOthers[6]];
  for (let i = 0; i < makolaOrder.length; i++) {
    await db.circleMember.create({
      data: { circleId: makola.id, userId: makolaOrder[i].id, position: i + 1, payoutRound: i + 1, paidOut: i + 1 < 4 },
    });
  }
  // Ama's contributions rounds 1-3 + her payout (round 3)
  for (let r = 1; r <= 3; r++) {
    await transfer({ type: "contribution", description: `Makola Market Circle · round ${r}`, userId: ama.id, fromKey: acctKey("wallet", ama.id), toKey: acctKey("pool", makola.id), amountCents: 5000, txHash: ["f3a91c", "a7b22d", "9e44f1"][r - 1], createdAt: daysAgo(21 - (r - 1) * 7) });
    await db.contribution.create({ data: { circleId: makola.id, userId: ama.id, round: r, amountCents: 5000, txHash: ["f3a91c", "a7b22d", "9e44f1"][r - 1], status: "confirmed", createdAt: daysAgo(21 - (r - 1) * 7) } });
  }
  await transfer({ type: "payout", description: "Makola Market Circle · round 3 payout", userId: ama.id, fromKey: acctKey("pool", makola.id), toKey: acctKey("wallet", ama.id), amountCents: 40000, txHash: "pay9e4f", createdAt: daysAgo(7) });
  // other members' contributions for rounds 1-3 (records for round completeness)
  for (const m of makolaOthers) {
    for (let r = 1; r <= 3; r++) {
      await db.contribution.create({ data: { circleId: makola.id, userId: m.id, round: r, amountCents: 5000, status: "confirmed", createdAt: daysAgo(21 - (r - 1) * 7) } });
    }
  }
  // round 4 in progress: two others have paid, Ama has not
  for (const m of [makolaOthers[0], makolaOthers[1]]) {
    await db.contribution.create({ data: { circleId: makola.id, userId: m.id, round: 4, amountCents: 5000, status: "confirmed", createdAt: daysAgo(1) } });
  }

  // ---- Family Savings: monthly, 6 members, round 2 of 6 ----
  const family = await db.circle.create({
    data: {
      name: "Family Savings",
      status: "active",
      contributionCents: 10000,
      frequency: "monthly",
      totalRounds: 6,
      currentRound: 2,
      startDate: new Date("2026-04-28T00:00:00Z"),
      contractAddress: "CDFAM92SUSU2KABCDEFGHIJKLMNOPQRSTUVWXYZ234567ABCDEF",
      createdById: ama.id,
    },
  });
  const familyOrder = [ama, ...familyOthers];
  for (let i = 0; i < familyOrder.length; i++) {
    await db.circleMember.create({
      data: { circleId: family.id, userId: familyOrder[i].id, position: i + 1, payoutRound: i + 1, paidOut: i === 0 },
    });
  }
  await transfer({ type: "contribution", description: "Family Savings · round 1", userId: ama.id, fromKey: acctKey("wallet", ama.id), toKey: acctKey("pool", family.id), amountCents: 10000, txHash: "11ab3c", createdAt: daysAgo(34) });
  await db.contribution.create({ data: { circleId: family.id, userId: ama.id, round: 1, amountCents: 10000, txHash: "11ab3c", status: "confirmed", createdAt: daysAgo(34) } });
  await transfer({ type: "payout", description: "Family Savings · round 1 payout", userId: ama.id, fromKey: acctKey("pool", family.id), toKey: acctKey("wallet", ama.id), amountCents: 60000, txHash: "pay11ab", createdAt: daysAgo(34) });
  for (const m of familyOthers) {
    await db.contribution.create({ data: { circleId: family.id, userId: m.id, round: 1, amountCents: 10000, status: "confirmed", createdAt: daysAgo(34) } });
  }

  // ---- Accra Tech Savers: forming ----
  const tech = await db.circle.create({
    data: {
      name: "Accra Tech Savers",
      status: "forming",
      contributionCents: 25000,
      frequency: "monthly",
      totalRounds: 3,
      currentRound: 0,
      startDate: new Date("2026-06-30T00:00:00Z"),
      createdById: ama.id,
    },
  });
  const techOrder = [ama, ...techOthers];
  for (let i = 0; i < techOrder.length; i++) {
    await db.circleMember.create({
      data: { circleId: tech.id, userId: techOrder[i].id, position: i + 1, payoutRound: i + 1 },
    });
  }

  console.log("Lesson progress…");
  await db.lessonProgress.create({ data: { userId: ama.id, slug: "what-is-susu" } });

  console.log("✔ Seed complete.");
  console.log(`   Demo login:  ama@moolahub.io  /  ${DEMO_PASSWORD}`);
  void makolaMembers;
}

main()
  .then(() => db.$disconnect())
  .catch(async (e) => {
    console.error(e);
    await db.$disconnect();
    process.exit(1);
  });
