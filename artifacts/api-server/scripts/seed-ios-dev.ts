/**
 * seed-ios-dev: demo data for the native iOS dev build. LOCAL DATABASES ONLY.
 *
 * Usage (scripts/dev-ios-backend.sh at the repo root runs this for you):
 *   DATABASE_URL=postgres://localhost:5432/moolahub_ios_dev APP_ENCRYPTION_KEY=<64 hex> \
 *     pnpm --filter @workspace/api-server run seed:ios-dev            # seed, or no-op if already seeded
 *   ...same... run seed:ios-dev --reset                               # wipe the demo users' data, then reseed
 *
 * DEMO LOGIN (a test credential for a local development database only; it is
 * not, and must never become, a real account's password):
 *   email:    demo@moolahub.test   (DEMO_EMAIL below)
 *   password: DEMO_PASSWORD below. All four friends use the same password.
 *
 * Safety. It refuses to run unless:
 *   - DATABASE_URL (and MIGRATIONS_DATABASE_URL, if set) points at localhost or
 *     127.0.0.1;
 *   - NODE_ENV is not "production";
 *   - no chain or email configuration is set (PLATFORM_PRIVATE_KEY,
 *     USDC_CONTRACT_ADDRESS, the contract addresses, RESEND_API_KEY): everything
 *     it books is ledger-only test money and no email ever leaves the machine;
 *   - APP_ENCRYPTION_KEY is set (wallet keys are encrypted at rest).
 *
 * Idempotent. Re-running when the seed is complete only re-applies the demo
 * password, the verified flag and reactivation to the five demo accounts (so the
 * login above always works) and touches nothing else. A previous run that died
 * half-way is detected and rebuilt from scratch.
 *
 * --reset wipes ONLY the demo users' data and reseeds: the five accounts, their
 * wallets, goals, ledger history, sessions and notifications, and every circle a
 * demo user created, joined, contributed to or was invited into by a demo user.
 * That includes a circle you created in the app and added a demo friend to,
 * because a circle's history can't exist without its members. Uses the same
 * owner-only ledger purge the e2e suites use (@workspace/db/testing).
 *
 * Everything money-related goes through the app's own domain functions, so the
 * double-entry ledger is exactly what the API would have booked: faucetDeposit
 * (the ledger-only test faucet), createGoal / allocateToGoal / releaseFromGoal,
 * createCircle / acceptInvite / startCircle / contribute (which also books the
 * rotation payouts). Only the user rows themselves are inserted directly, the
 * same way the e2e suites create verified accounts.
 *
 * History across months: after each step, the rows that step created for the
 * demo users (ledger transactions, circle contributions, invites, notifications)
 * have their timestamps moved back to that step's date, and goal / circle /
 * user creation and circle start dates are set to match. Only timestamps move;
 * every amount and posting is exactly what the domain functions booked.
 *
 * What you get (amounts are test money):
 *   - demo (Ama Owusu, @ama) and friends Kofi, Esi, Yaw, Abena: verified, with
 *     usernames and names, each with test money;
 *   - 2 goals for the demo user ("Emergency fund", "New laptop") funded over five
 *     months, including one move back to the balance;
 *   - "Family susu": rotating, Kofi + Esi + Yaw + demo, monthly $100, started
 *     50 days ago, rounds 1-2 paid out (Kofi, Esi), round 3 under way (Yaw's
 *     turn) with the demo user's $100 still due; demo's turn is round 4;
 *   - "Holiday pot": accumulation created by demo with Abena + Yaw, monthly $50
 *     for 6 rounds, rounds 1-3 complete, round 4 paid by demo and Abena (Yaw due);
 *   - "Wedding fund": Esi's forming rotating circle (Abena joined) with a pending
 *     invite to the demo user;
 *   - the notifications those actions produce; ones older than a week are read.
 */
// ---------------------------------------------------------------- constants

/** Local-dev test credential (see the header). Shared by all five demo users. */
export const DEMO_PASSWORD = "Moolahub-demo-2026";
export const DEMO_EMAIL = "demo@moolahub.test";

const PEOPLE = [
  { key: "demo", name: "Ama Owusu", username: "ama", email: DEMO_EMAIL },
  { key: "kofi", name: "Kofi Mensah", username: "kofi", email: "kofi@moolahub.test" },
  { key: "esi", name: "Esi Boateng", username: "esi", email: "esi@moolahub.test" },
  { key: "yaw", name: "Yaw Asante", username: "yaw", email: "yaw@moolahub.test" },
  { key: "abena", name: "Abena Darko", username: "abena", email: "abena@moolahub.test" },
] as const;
type PersonKey = (typeof PEOPLE)[number]["key"];
type People = Record<PersonKey, { id: string; email: string }>;

const FAMILY_SUSU = "Family susu";
const HOLIDAY_POT = "Holiday pot";
const WEDDING_FUND = "Wedding fund";

const RESET = process.argv.includes("--reset");

// ----------------------------------------------------------- safety gates
// All checks run BEFORE anything that opens a database connection is imported.

function refuse(message: string): never {
  console.error(`seed-ios-dev: refusing to run: ${message}`);
  process.exit(1);
}

const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1"]);

function hostOf(url: string, name: string): string {
  try {
    return new URL(url).hostname;
  } catch {
    refuse(`${name} is not a valid postgres:// URL`);
  }
}

const databaseUrl = process.env.DATABASE_URL;
if (!databaseUrl) refuse("DATABASE_URL is not set");
const dbHost = hostOf(databaseUrl, "DATABASE_URL");
if (!LOCAL_HOSTS.has(dbHost)) {
  refuse(`DATABASE_URL points at "${dbHost || "(unix socket)"}"; only localhost / 127.0.0.1 are allowed`);
}
const migrationsUrl = process.env.MIGRATIONS_DATABASE_URL;
if (migrationsUrl && !LOCAL_HOSTS.has(hostOf(migrationsUrl, "MIGRATIONS_DATABASE_URL"))) {
  refuse("MIGRATIONS_DATABASE_URL is set to a non-local database (the --reset purge would use it)");
}
if (process.env.NODE_ENV === "production") refuse("NODE_ENV is production");
for (const name of [
  "PLATFORM_PRIVATE_KEY",
  "USDC_CONTRACT_ADDRESS",
  "GOAL_VAULT_ADDRESS",
  "CIRCLE_FACTORY_ADDRESS",
  "ACCUMULATION_FACTORY_ADDRESS",
  "RESEND_API_KEY",
]) {
  if (process.env[name]) refuse(`${name} is set; this seed is offline-only (ledger test money, no email)`);
}
if (!process.env.APP_ENCRYPTION_KEY) refuse("APP_ENCRYPTION_KEY is not set (wallet keys are encrypted at rest)");

// ------------------------------------------------------------------ imports

const { db, pool, usersTable, goalsTable, circlesTable, circleInvitesTable } = await import("@workspace/db");
const { purgeTestData } = await import("@workspace/db/testing");
const { and, eq, inArray } = await import("drizzle-orm");
const { hashPassword } = await import("../src/lib/password");
const { onchainEnabled } = await import("../src/lib/chain");
const { createWalletForUser } = await import("../src/lib/wallet");
const { faucetDeposit } = await import("../src/lib/deposits");
const { createGoal, allocateToGoal, releaseFromGoal } = await import("../src/lib/goals");
const { createCircle, acceptInvite, startCircle, contribute } = await import("../src/lib/circles");
const { acct, accountBalance } = await import("../src/lib/ledger");

if (onchainEnabled()) refuse("on-chain settlement is configured; this seed is offline-only");

// ------------------------------------------------------------------ helpers

const DAY_MS = 24 * 60 * 60 * 1000;
const NOW = Date.now();
const daysAgo = (d: number) => new Date(NOW - d * DAY_MS);
const daysAhead = (d: number) => new Date(NOW + d * DAY_MS);
const dollars = (cents: number) => `$${(cents / 100).toFixed(2)}`;

function log(message: string): void {
  console.log(`seed-ios-dev: ${message}`);
}

async function findPeople(): Promise<Partial<People>> {
  const rows = await db
    .select({ id: usersTable.id, email: usersTable.email })
    .from(usersTable)
    .where(
      inArray(
        usersTable.email,
        PEOPLE.map((p) => p.email),
      ),
    );
  const found: Partial<People> = {};
  for (const p of PEOPLE) {
    const row = rows.find((r) => r.email === p.email);
    if (row) found[p.key] = { id: row.id, email: row.email };
  }
  return found;
}

/** "complete" | "empty" | "partial" for the demo data currently in the DB. */
async function seedState(found: Partial<People>): Promise<"complete" | "empty" | "partial"> {
  const present = PEOPLE.filter((p) => found[p.key]).length;
  if (present === 0) return "empty";
  if (present < PEOPLE.length || !found.esi) return "partial";
  // The last thing the seed creates is Esi's "Wedding fund" with its invite to
  // the demo user. Accepting or declining it in the app keeps the row, and only
  // its creator could delete the circle, so this marker survives normal QA.
  const [wedding] = await db
    .select({ id: circlesTable.id })
    .from(circlesTable)
    .where(and(eq(circlesTable.createdById, found.esi.id), eq(circlesTable.name, WEDDING_FUND)));
  if (!wedding) return "partial";
  const [invite] = await db
    .select({ id: circleInvitesTable.id })
    .from(circleInvitesTable)
    .where(and(eq(circleInvitesTable.circleId, wedding.id), eq(circleInvitesTable.email, DEMO_EMAIL)));
  return invite ? "complete" : "partial";
}

/** Wipe the given demo users and everything that hangs off them (see header). */
async function wipe(userIds: string[]): Promise<void> {
  if (!userIds.length) return;
  const circles = await pool.query<{ id: string }>(
    `SELECT id FROM circles WHERE created_by_id = ANY($1::uuid[])
     UNION SELECT circle_id FROM circle_members WHERE user_id = ANY($1::uuid[])
     UNION SELECT circle_id FROM contributions WHERE user_id = ANY($1::uuid[])
     UNION SELECT circle_id FROM circle_invites WHERE invited_by_id = ANY($1::uuid[])`,
    [userIds],
  );
  await purgeTestData({ userIds, circleIds: circles.rows.map((r) => r.id) });
  log(`wiped ${userIds.length} demo user(s) and ${circles.rowCount ?? 0} circle(s)`);
}

/** Re-apply the demo login to existing accounts (password, verified, active). */
async function refreshCredentials(found: Partial<People>): Promise<void> {
  const passwordHash = await hashPassword(DEMO_PASSWORD);
  for (const p of PEOPLE) {
    const person = found[p.key];
    if (!person) continue;
    const [row] = await db.select().from(usersTable).where(eq(usersTable.id, person.id));
    await db
      .update(usersTable)
      .set({ passwordHash, emailVerifiedAt: row?.emailVerifiedAt ?? new Date(), deactivatedAt: null })
      .where(eq(usersTable.id, person.id));
    if (row?.twoFactorEnabled) log(`note: ${p.email} has 2FA enabled (left as is)`);
  }
}

async function createPeople(): Promise<People> {
  const passwordHash = await hashPassword(DEMO_PASSWORD);
  const people = {} as People;
  for (const p of PEOPLE) {
    const [row] = await db
      .insert(usersTable)
      .values({
        name: p.name,
        username: p.username,
        email: p.email,
        passwordHash,
        emailVerifiedAt: daysAgo(150),
        dateOfBirth: "1993-04-21",
        referralSource: "Friends",
        createdAt: daysAgo(150),
      })
      .returning();
    // The same server-custody, ledger-only wallet every offline e2e suite uses.
    // With on-chain disabled (checked above) it never signs or settles anything.
    await createWalletForUser(row.id);
    people[p.key] = { id: row.id, email: row.email };
  }
  return people;
}

/**
 * Run one dated step: execute `fn`, then move the timestamps of the rows it
 * created for the demo users (and the given circles) back to `when`, keeping
 * their relative order. Amounts and postings are never touched.
 */
async function at(when: Date, label: string, userIds: string[], circleIds: string[], fn: () => Promise<void>) {
  const started = new Date(Date.now() - 1000);
  await fn();
  const shift = `$2::timestamptz + (created_at - $1::timestamptz)`;
  await pool.query(
    `UPDATE transactions SET created_at = ${shift}
      WHERE created_at >= $1 AND (user_id = ANY($3::uuid[]) OR circle_id = ANY($4::uuid[]))`,
    [started, when, userIds, circleIds],
  );
  for (const table of ["contributions", "notifications"]) {
    await pool.query(
      `UPDATE ${table} SET created_at = ${shift} WHERE created_at >= $1 AND user_id = ANY($3::uuid[])`,
      [started, when, userIds],
    );
  }
  await pool.query(
    `UPDATE circle_invites SET created_at = ${shift}, updated_at = ${shift}
      WHERE created_at >= $1 AND circle_id = ANY($3::uuid[])`,
    [started, when, circleIds],
  );
  log(`${when.toISOString().slice(0, 10)}  ${label}`);
}

async function inviteId(circleId: string, email: string): Promise<string> {
  const [row] = await db
    .select({ id: circleInvitesTable.id })
    .from(circleInvitesTable)
    .where(and(eq(circleInvitesTable.circleId, circleId), eq(circleInvitesTable.email, email)));
  if (!row) throw new Error(`no invite for ${email} in circle ${circleId}`);
  return row.id;
}

async function accept(people: People, who: PersonKey, circleId: string): Promise<void> {
  const p = people[who];
  await acceptInvite(p.id, p.email, await inviteId(circleId, p.email));
}

// --------------------------------------------------------------------- seed

async function seed(people: People): Promise<void> {
  const ids = PEOPLE.map((p) => people[p.key].id);
  const circleIds: string[] = [];
  const demo = people.demo.id;
  let emergencyId = "";
  let laptopId = "";
  let familyId = "";
  let holidayId = "";

  await at(daysAgo(140), "demo adds test money, creates 2 goals, saves", ids, circleIds, async () => {
    await faucetDeposit(demo, 80_000);
    const emergency = await createGoal(demo, {
      name: "Emergency fund",
      emoji: "🛟",
      targetCents: 300_000,
      deadline: daysAhead(180),
      frequency: "monthly",
      autoSaveCents: 25_000,
      color: "jade",
    });
    const laptop = await createGoal(demo, {
      name: "New laptop",
      emoji: "💻",
      targetCents: 120_000,
      deadline: daysAhead(90),
      frequency: "monthly",
      autoSaveCents: 15_000,
      color: "jade",
    });
    emergencyId = emergency.id;
    laptopId = laptop.id;
    await db.update(goalsTable).set({ createdAt: daysAgo(140) }).where(inArray(goalsTable.id, [emergencyId, laptopId]));
    await allocateToGoal(demo, emergencyId, 25_000);
  });

  await at(daysAgo(120), "friends add test money", ids, circleIds, async () => {
    for (const key of ["kofi", "esi", "yaw", "abena"] as const) {
      await faucetDeposit(people[key].id, 100_000);
      await faucetDeposit(people[key].id, 100_000);
    }
  });

  await at(daysAgo(110), "demo adds test money and saves", ids, circleIds, async () => {
    await faucetDeposit(demo, 60_000);
    await allocateToGoal(demo, emergencyId, 25_000);
    await allocateToGoal(demo, laptopId, 15_000);
  });

  await at(daysAgo(85), `demo creates "${HOLIDAY_POT}", Abena and Yaw join`, ids, circleIds, async () => {
    const holiday = await createCircle(demo, {
      name: HOLIDAY_POT,
      type: "accumulation",
      contributionCents: 5_000,
      numRounds: 6,
      frequency: "monthly",
      memberEmails: [people.abena.email, people.yaw.email],
    });
    holidayId = holiday.id;
    circleIds.push(holidayId);
    await accept(people, "abena", holidayId);
    await accept(people, "yaw", holidayId);
  });
  await db.update(circlesTable).set({ createdAt: daysAgo(85) }).where(eq(circlesTable.id, holidayId));

  await at(daysAgo(80), `"${HOLIDAY_POT}" starts, round 1; demo adds money and saves`, ids, circleIds, async () => {
    await faucetDeposit(demo, 70_000);
    await startCircle(demo, holidayId);
    for (const key of ["demo", "abena", "yaw"] as const) await contribute(people[key].id, holidayId);
    await allocateToGoal(demo, emergencyId, 25_000);
    await allocateToGoal(demo, laptopId, 15_000);
  });
  await db.update(circlesTable).set({ startDate: daysAgo(80) }).where(eq(circlesTable.id, holidayId));

  await at(daysAgo(55), `Kofi creates "${FAMILY_SUSU}", Esi, Yaw and demo join`, ids, circleIds, async () => {
    const family = await createCircle(people.kofi.id, {
      name: FAMILY_SUSU,
      type: "rotation",
      contributionCents: 10_000,
      frequency: "monthly",
      memberEmails: [people.esi.email, people.yaw.email, people.demo.email],
    });
    familyId = family.id;
    circleIds.push(familyId);
    await accept(people, "esi", familyId);
    await accept(people, "yaw", familyId);
    await accept(people, "demo", familyId);
  });
  await db.update(circlesTable).set({ createdAt: daysAgo(55) }).where(eq(circlesTable.id, familyId));

  await at(daysAgo(50), `"${FAMILY_SUSU}" starts, round 1 paid out; "${HOLIDAY_POT}" round 2`, ids, circleIds, async () => {
    await faucetDeposit(demo, 90_000);
    await startCircle(people.kofi.id, familyId);
    for (const key of ["kofi", "esi", "yaw", "demo"] as const) await contribute(people[key].id, familyId);
    for (const key of ["demo", "abena", "yaw"] as const) await contribute(people[key].id, holidayId);
    await allocateToGoal(demo, emergencyId, 30_000);
    await allocateToGoal(demo, laptopId, 15_000);
  });
  await db.update(circlesTable).set({ startDate: daysAgo(50) }).where(eq(circlesTable.id, familyId));

  await at(daysAgo(20), `"${FAMILY_SUSU}" round 2 paid out; "${HOLIDAY_POT}" round 3; demo moves money`, ids, circleIds, async () => {
    await faucetDeposit(demo, 50_000);
    for (const key of ["kofi", "esi", "yaw", "demo"] as const) await contribute(people[key].id, familyId);
    for (const key of ["demo", "abena", "yaw"] as const) await contribute(people[key].id, holidayId);
    await allocateToGoal(demo, emergencyId, 20_000);
    await releaseFromGoal(demo, laptopId, 12_000);
  });

  await at(daysAgo(3), `"${FAMILY_SUSU}" round 3 (demo due); "${HOLIDAY_POT}" round 4 (Yaw due)`, ids, circleIds, async () => {
    for (const key of ["kofi", "esi", "yaw"] as const) await contribute(people[key].id, familyId);
    for (const key of ["demo", "abena"] as const) await contribute(people[key].id, holidayId);
  });

  await at(daysAgo(1), `Esi creates "${WEDDING_FUND}" and invites demo + Abena; Abena joins`, ids, circleIds, async () => {
    const wedding = await createCircle(people.esi.id, {
      name: WEDDING_FUND,
      type: "rotation",
      contributionCents: 2_500,
      frequency: "weekly",
      memberEmails: [people.demo.email, people.abena.email],
    });
    circleIds.push(wedding.id);
    await db.update(circlesTable).set({ createdAt: daysAgo(1) }).where(eq(circlesTable.id, wedding.id));
    await accept(people, "abena", wedding.id);
  });

  // Older notifications have been seen; the last week's stay unread.
  await pool.query(
    `UPDATE notifications SET read = true WHERE user_id = ANY($1::uuid[]) AND created_at < $2`,
    [ids, daysAgo(7)],
  );
}

// --------------------------------------------------------------------- main

async function summary(people: Partial<People>): Promise<void> {
  for (const p of PEOPLE) {
    const person = people[p.key];
    if (!person) continue;
    const available = await accountBalance(acct.wallet(person.id));
    log(`  ${p.email.padEnd(22)} @${p.username.padEnd(6)} available ${dollars(available)}`);
  }
  if (people.demo) {
    const goals = await db.select().from(goalsTable).where(eq(goalsTable.userId, people.demo.id));
    for (const g of goals) {
      log(`  goal "${g.name}": ${dollars(await accountBalance(acct.goal(g.id)))} of ${dollars(g.targetCents)}`);
    }
  }
  log(`Demo login: ${DEMO_EMAIL} / the DEMO_PASSWORD constant in artifacts/api-server/scripts/seed-ios-dev.ts`);
}

async function main(): Promise<void> {
  log(`database ${new URL(databaseUrl!).pathname.slice(1)} on ${dbHost}${RESET ? " (--reset)" : ""}`);
  const found = await findPeople();
  const existingIds = Object.values(found).map((p) => p.id);

  if (RESET) {
    await wipe(existingIds);
  } else {
    const state = await seedState(found);
    if (state === "complete") {
      await refreshCredentials(found);
      log("demo data already present; re-applied the demo login (use --reset to rebuild)");
      await summary(found);
      return;
    }
    if (state === "partial") {
      log("found an incomplete earlier seed; rebuilding the demo data");
      await wipe(existingIds);
    }
  }

  const people = await createPeople();
  await seed(people);
  log("seeded");
  await summary(people);
}

let failed = false;
try {
  await main();
} catch (e) {
  failed = true;
  console.error("seed-ios-dev: FAILED", e);
} finally {
  await pool.end();
}
process.exit(failed ? 1 : 0);
