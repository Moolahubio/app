import { eq, and, inArray, desc, asc, count } from "drizzle-orm";
import {
  db,
  circlesTable,
  circleMembersTable,
  circleInvitesTable,
  contributionsTable,
  usersTable,
} from "@workspace/db";
import { acct, transfer, accountBalance } from "./ledger";
import { onchainEnabled, deployCircleEscrow, explorerUrl } from "./chain";
import { enqueueOnchainTransfer, kickReconciler } from "./settlement";
import { sendEmail, brandedEmail, appUrl } from "./email";
import { notify, notifyMany } from "./notifications";
import { formatMoney } from "./money";

const INTERVAL_DAYS: Record<string, number> = { weekly: 7, biweekly: 14, monthly: 30 };

// Platform fee on each rotation payout, mirroring the on-chain escrow's feeBps
// (the deployed CircleFactory uses 200 = 2%). A recipient owed `pot` receives
// `pot - fee`; the fee leaves the pool to the treasury on-chain.
const FEE_BPS = Number(process.env.CIRCLE_FEE_BPS) || 200;
// Grace period after a round's deadline before it can be flagged/cancelled
// on-chain. Generous so testnet circles never auto-stall.
const GRACE_PERIOD_DAYS = 7;

function feeCentsOf(potCents: number): number {
  return Math.floor((potCents * FEE_BPS) / 10_000);
}

function addInterval(start: Date | null, frequency: string, rounds: number): Date {
  const d = new Date(start ?? Date.now());
  d.setDate(d.getDate() + (INTERVAL_DAYS[frequency] ?? 30) * rounds);
  return d;
}

/**
 * How much each member receives from a circle.
 * - Accumulation: your own savings back at the end (contribution × rounds).
 * - Rotation: the full pot when it's your turn (contribution × members).
 * Falls back to the stored payout once finalized, else a live estimate.
 */
function receivePerPerson(
  c: { type: string; contributionCents: number; totalRounds: number; payoutCents: number | null },
  memberCount: number,
): number {
  if (c.type === "accumulation") {
    return c.payoutCents ?? c.contributionCents * c.totalRounds;
  }
  return c.payoutCents ?? c.contributionCents * memberCount;
}

export type MemberState = "paid" | "current" | "upcoming";

function memberState(payoutRound: number, currentRound: number, paidOut: boolean): MemberState {
  if (paidOut || payoutRound < currentRound) return "paid";
  if (payoutRound === currentRound) return "current";
  return "upcoming";
}

async function memberCircleIds(userId: string): Promise<string[]> {
  const rows = await db
    .select({ circleId: circleMembersTable.circleId })
    .from(circleMembersTable)
    .where(eq(circleMembersTable.userId, userId));
  return rows.map((r) => r.circleId);
}

export async function createCircle(
  userId: string,
  input: {
    name: string;
    type?: string;
    contributionCents: number;
    numRounds?: number;
    frequency: string;
    memberEmails?: string[];
    imageUrl?: string | null;
  },
) {
  if (!input.name?.trim()) throw new Error("Circle name is required.");
  if (input.contributionCents <= 0) throw new Error("Enter a contribution amount.");
  const type = input.type === "accumulation" ? "accumulation" : "rotation";

  // For accumulation circles the organizer chooses how many rounds the circle
  // runs, and each member receives their own savings back (contribution × rounds)
  // at the end. For rotation, rounds are derived from member count at start, and
  // the payout (full pot) is finalized then.
  let totalRounds = 1;
  let payoutCents: number | null = null;
  if (type === "accumulation") {
    const rounds = Math.floor(input.numRounds ?? 0);
    if (rounds < 2) throw new Error("Choose at least 2 rounds for an accumulation circle.");
    totalRounds = rounds;
    payoutCents = input.contributionCents * rounds;
  }

  const [circle] = await db
    .insert(circlesTable)
    .values({
      name: input.name.trim(),
      createdById: userId,
      imageUrl: input.imageUrl ?? null,
      type,
      contributionCents: input.contributionCents,
      payoutCents,
      frequency: input.frequency || "monthly",
      status: "forming",
      currentRound: 0,
      totalRounds,
    })
    .returning();

  await db.insert(circleMembersTable).values({
    circleId: circle.id,
    userId,
    position: 1,
    payoutRound: 1,
  });

  const emails = (input.memberEmails ?? [])
    .map((e) => e.trim().toLowerCase())
    .filter((e) => e && e.includes("@"));
  for (const email of emails) {
    await inviteToCircle(userId, circle.id, email).catch(() => undefined);
  }
  return circle;
}

export async function listCirclesForUser(userId: string) {
  const ids = await memberCircleIds(userId);
  if (!ids.length) return [];
  const circles = await db.query.circlesTable.findMany({
    where: inArray(circlesTable.id, ids),
    with: { members: { with: { user: true } } },
    orderBy: desc(circlesTable.createdAt),
  });
  return circles.map((c) => {
    const memberCount = c.members.length;
    const me = c.members.find((m) => m.userId === userId);
    return {
      id: c.id,
      name: c.name,
      status: c.status,
      type: c.type,
      frequency: c.frequency,
      contributionCents: c.contributionCents,
      payoutCents: receivePerPerson(c, memberCount),
      potCents: c.contributionCents * memberCount,
      memberCount,
      myPayoutRound: me?.payoutRound ?? 0,
      currentRound: c.currentRound,
      totalRounds: c.totalRounds,
      imageUrl: c.imageUrl ?? null,
      nextPayoutDate: c.startDate
        ? addInterval(c.startDate, c.frequency, Math.max(0, c.currentRound - 1)).toISOString()
        : null,
    };
  });
}

export async function getCircleDetail(userId: string, circleId: string) {
  const ids = await memberCircleIds(userId);
  if (!ids.includes(circleId)) return null;
  const c = await db.query.circlesTable.findFirst({
    where: eq(circlesTable.id, circleId),
    with: {
      members: { with: { user: true }, orderBy: asc(circleMembersTable.position) },
      contributions: true,
      invites: true,
    },
  });
  if (!c) return null;

  const memberCount = c.members.length;
  const me = c.members.find((m) => m.userId === userId);
  const myContributions = c.contributions.filter((x) => x.userId === userId);
  const contributedThisRound = myContributions.some((x) => x.round === c.currentRound);
  const isCreator = c.createdById === userId;
  const pendingInvites = c.invites.filter((i) => i.status === "pending");

  return {
    id: c.id,
    name: c.name,
    status: c.status,
    type: c.type,
    frequency: c.frequency,
    contributionCents: c.contributionCents,
    payoutCents: receivePerPerson(c, memberCount),
    potCents: c.contributionCents * memberCount,
    memberCount,
    totalRounds: c.totalRounds,
    currentRound: c.currentRound,
    imageUrl: c.imageUrl ?? null,
    startDate: c.startDate ? c.startDate.toISOString() : null,
    contractAddress: c.contractAddress,
    // Rotation circles settle on-chain through the escrow, which takes the same
    // fee the ledger mirrors; accumulation stays ledger-only with no fee.
    feeBps: c.type === "accumulation" ? 0 : FEE_BPS,
    explorerUrl: c.contractAddress ? explorerUrl() : null,
    myPayoutRound: me?.payoutRound ?? null,
    myContributionStatus: contributedThisRound ? "paid" : "due",
    isCreator,
    canInvite: isCreator && c.status === "forming",
    canStart: isCreator && c.status === "forming" && memberCount >= 2,
    canContribute: c.status === "active" && !contributedThisRound && !!me,
    pendingInvites: pendingInvites.map((i) => ({ id: i.id, email: i.email })),
    members: c.members.map((m) => ({
      id: m.id,
      name: m.user.name,
      position: m.position,
      payoutRound: m.payoutRound,
      paidOut: m.paidOut,
      state: memberState(m.payoutRound, c.currentRound, m.paidOut),
      contributedThisRound: c.contributions.some(
        (x) => x.userId === m.userId && x.round === c.currentRound,
      ),
    })),
    history: myContributions
      .sort((a, b) => a.round - b.round)
      .map((h) => ({
        id: h.id,
        round: h.round,
        amountCents: h.amountCents,
        txHash: h.txHash,
        status: h.status,
        createdAt: h.createdAt.toISOString(),
      })),
  };
}

/** Make this round's contribution; trigger the payout when the round fills. */
export async function contribute(userId: string, circleId: string) {
  const ids = await memberCircleIds(userId);
  if (!ids.includes(circleId)) throw new Error("Circle not found");
  const [circle] = await db.select().from(circlesTable).where(eq(circlesTable.id, circleId));
  if (!circle) throw new Error("Circle not found");
  if (circle.status !== "active") throw new Error("Circle is not active");
  const round = circle.currentRound;

  // Non-authoritative pre-checks, purely for friendly error messages. The real
  // guards run inside the atomic transaction below.
  const [already] = await db
    .select({ id: contributionsTable.id })
    .from(contributionsTable)
    .where(
      and(
        eq(contributionsTable.circleId, circleId),
        eq(contributionsTable.userId, userId),
        eq(contributionsTable.round, round),
      ),
    );
  if (already) throw new Error("You've already contributed this round");

  if ((await accountBalance(acct.wallet(userId))) < circle.contributionCents) {
    throw new Error("Insufficient available balance");
  }

  // On-chain settlement is member wallet → the circle's Susu escrow contract.
  // Only rotation circles with a deployed escrow settle on-chain; accumulation
  // and any ledger-only-fallback rotation circle stay ledger-only. Resolve the
  // escrow address before the tx; null disables on-chain for this contribution.
  const escrow =
    circle.type !== "accumulation" && circle.contractAddress && onchainEnabled()
      ? circle.contractAddress
      : null;

  // Reserve the contribution slot and move the money in ONE transaction so they
  // commit or roll back together. The unique (circle_id, user_id, round)
  // constraint is the authoritative race guard: a concurrent second request
  // hits onConflictDoNothing → 0 rows → we throw and the whole tx (including the
  // ledger postings) rolls back, so no double-debit is possible. The on-chain
  // settlement is enqueued in the SAME tx, then settled out of band by the
  // reconciler — never silently dropped to ledger-only.
  const { txn } = await db.transaction(async (tx) => {
    const reserved = await tx
      .insert(contributionsTable)
      .values({
        circleId,
        userId,
        round,
        amountCents: circle.contributionCents,
        status: "confirmed",
      })
      .onConflictDoNothing({
        target: [contributionsTable.circleId, contributionsTable.userId, contributionsTable.round],
      })
      .returning({ id: contributionsTable.id });
    if (reserved.length === 0) throw new Error("You've already contributed this round");

    const t = await transfer({
      type: "contribution",
      description: `${circle.name} · round ${round}`,
      userId,
      fromKey: acct.wallet(userId),
      toKey: acct.pool(circleId),
      amountCents: circle.contributionCents,
      onchain: escrow ? { onchainStatus: "pending" } : { onchainStatus: "none" },
      requireSufficientFrom: true,
      circleId,
      round,
      tx,
    });
    if (escrow) {
      await enqueueOnchainTransfer(
        {
          transactionId: t.id,
          contributionId: reserved[0].id,
          kind: "escrow_contribute",
          sourceUserId: userId,
          toAddress: escrow,
          amountCents: circle.contributionCents,
          memo: `susu:${circleId}:${round}`,
        },
        tx,
      );
    }
    return { txn: t, contributionId: reserved[0].id };
  });

  // Create the round's payout/fee ledger rows BEFORE kicking the reconciler.
  // The escrow settles the round on-chain when the last member contributes, and
  // the reconciler stamps those payout/fee rows confirmed by (circleId, round)
  // when it sees `RoundSettled`. If the rows didn't exist yet, that backfill
  // would update 0 rows and the payout would be stranded as "pending" with no
  // retry path. Building them first — and only then kicking the reconciler —
  // guarantees they're present (the on-chain contribute also takes seconds,
  // so even the live interval reconciler can't outrun this fast ledger write).
  await maybeProcessPayout(circleId, round);

  if (escrow) kickReconciler();

  await notify(
    userId,
    {
      type: "contribution",
      title: `Contributed to ${circle.name}`,
      body: `You paid ${formatMoney(circle.contributionCents)} for round ${round}.`,
      link: `/circles/${circleId}`,
    },
    { email: true },
  );

  return txn;
}

/** If every member has contributed this round, pay the round's recipient. */
async function maybeProcessPayout(circleId: string, round: number) {
  const circle = await db.query.circlesTable.findFirst({
    where: eq(circlesTable.id, circleId),
    with: { members: { with: { user: { with: { wallet: true } } } } },
  });
  if (!circle) return;
  const [{ c: contribCount }] = await db
    .select({ c: count() })
    .from(contributionsTable)
    .where(and(eq(contributionsTable.circleId, circleId), eq(contributionsTable.round, round)));
  if (Number(contribCount) < circle.members.length) return;

  if (circle.type === "accumulation") {
    // Accumulation has no per-round recipient. Members save into the shared pool
    // each round; on the final round each member receives their own savings back
    // (contribution × rounds). Distribute then advance.
    if (round >= circle.totalRounds) {
      const shareCents = circle.contributionCents * circle.totalRounds;
      for (const member of circle.members) {
        if (member.paidOut) continue;

        // Accumulation circles stay ledger-only (no on-chain escrow), so the
        // savings-return payout is a pure ledger move.
        // Claim and pay atomically in one transaction: flip paidOut false→true
        // alongside the ledger move so a concurrent caller can't double-pay
        // (the conditional update is the guard) and a failed transfer can't
        // strand a member as "paid" with no money moved.
        const paid = await db.transaction(async (tx) => {
          const claimed = await tx
            .update(circleMembersTable)
            .set({ paidOut: true })
            .where(and(eq(circleMembersTable.id, member.id), eq(circleMembersTable.paidOut, false)))
            .returning({ id: circleMembersTable.id });
          if (claimed.length === 0) return false;
          await transfer({
            type: "payout",
            description: `${circle.name} · savings returned`,
            userId: member.userId,
            fromKey: acct.pool(circleId),
            toKey: acct.wallet(member.userId),
            amountCents: shareCents,
            onchain: { onchainStatus: "none" },
            requireSufficientFrom: true,
            circleId,
            round,
            tx,
          });
          return true;
        });
        if (!paid) continue;
        await notify(
          member.userId,
          {
            type: "payout",
            title: "Your savings are back! 🎉",
            body: `${formatMoney(shareCents)} from "${circle.name}" landed in your wallet.`,
            link: `/circles/${circleId}`,
          },
          { email: true },
        );
      }
    }

    const nextRound = round + 1;
    if (nextRound > circle.totalRounds) {
      await db
        .update(circlesTable)
        .set({ status: "completed", currentRound: circle.totalRounds })
        .where(and(eq(circlesTable.id, circleId), eq(circlesTable.currentRound, round)));
    } else {
      await db
        .update(circlesTable)
        .set({ currentRound: nextRound })
        .where(and(eq(circlesTable.id, circleId), eq(circlesTable.currentRound, round)));
    }
    return;
  }

  const recipient = circle.members.find((m) => m.payoutRound === round);
  if (recipient && !recipient.paidOut) {
    // Atomically claim the payout: only one caller can flip paidOut false→true.
    // If another concurrent contribution already claimed it, skip — this is the
    // authoritative guard against double-paying the pot.
    const claimed = await db
      .update(circleMembersTable)
      .set({ paidOut: true })
      .where(and(eq(circleMembersTable.id, recipient.id), eq(circleMembersTable.paidOut, false)))
      .returning({ id: circleMembersTable.id });
    if (claimed.length === 0) return;

    const potCents = circle.contributionCents * circle.members.length;
    // On-chain rotation: the escrow settles the round itself (pays the recipient
    // their net and routes the fee to the treasury) atomically when the last
    // member contributes. We do NOT enqueue an on-chain payout — we mirror the
    // same economics in the ledger as "pending" and let the reconciler stamp the
    // settlement tx hash by circle+round once the escrow's RoundSettled fires.
    const onchainRotation = onchainEnabled() && !!circle.contractAddress;
    const feeCents = onchainRotation ? feeCentsOf(potCents) : 0;
    const netCents = potCents - feeCents;

    await db.transaction(async (tx) => {
      await transfer({
        type: "payout",
        description: `${circle.name} · round ${round} payout`,
        userId: recipient.userId,
        fromKey: acct.pool(circleId),
        toKey: acct.wallet(recipient.userId),
        amountCents: netCents,
        onchain: onchainRotation ? { onchainStatus: "pending" } : { onchainStatus: "none" },
        requireSufficientFrom: true,
        circleId,
        round,
        tx,
      });
      if (feeCents > 0) {
        // The fee leaves the pool to the treasury on-chain → ledger "external".
        await transfer({
          type: "fee",
          description: `${circle.name} · round ${round} platform fee`,
          userId: null,
          fromKey: acct.pool(circleId),
          toKey: acct.external,
          amountCents: feeCents,
          onchain: { onchainStatus: "pending" },
          requireSufficientFrom: true,
          circleId,
          round,
          tx,
        });
      }
    });
    await notify(
      recipient.userId,
      {
        type: "payout",
        title: "You received the pot! 🎉",
        body: `${formatMoney(netCents)} from "${circle.name}" landed in your wallet.`,
        link: `/circles/${circleId}`,
      },
      { email: true },
    );
  }

  // Advance only if we're still on `round` — conditional update makes this
  // idempotent so concurrent callers can't skip or double-advance the rotation.
  const nextRound = round + 1;
  if (nextRound > circle.totalRounds) {
    await db
      .update(circlesTable)
      .set({ status: "completed", currentRound: circle.totalRounds })
      .where(and(eq(circlesTable.id, circleId), eq(circlesTable.currentRound, round)));
  } else {
    await db
      .update(circlesTable)
      .set({ currentRound: nextRound })
      .where(and(eq(circlesTable.id, circleId), eq(circlesTable.currentRound, round)));
  }
}

// ---- Invitations ---------------------------------------------------------

export async function inviteToCircle(userId: string, circleId: string, emailRaw: string) {
  const email = emailRaw.trim().toLowerCase();
  if (!email || !email.includes("@")) throw new Error("Enter a valid email address.");
  const circle = await db.query.circlesTable.findFirst({
    where: and(eq(circlesTable.id, circleId), eq(circlesTable.createdById, userId)),
    with: { members: { with: { user: true } } },
  });
  if (!circle) throw new Error("Only the circle creator can invite members.");
  if (circle.status !== "forming") throw new Error("This circle has already started.");
  if (circle.members.some((m) => m.user.email === email)) {
    throw new Error("That person is already a member.");
  }
  await db
    .insert(circleInvitesTable)
    .values({ circleId, email, invitedById: userId, status: "pending" })
    .onConflictDoUpdate({
      target: [circleInvitesTable.circleId, circleInvitesTable.email],
      set: { status: "pending" },
    });

  const inviter = circle.members.find((m) => m.userId === userId)?.user.name ?? "A MoolaHub member";
  await sendEmail({
    to: email,
    subject: `${inviter} invited you to a Susu circle on MoolaHub`,
    html: brandedEmail({
      heading: `Join "${circle.name}"`,
      body: `${inviter} invited you to save together in the "${circle.name}" Susu circle — ${formatMoney(
        circle.contributionCents,
      )} per ${circle.frequency} round. Sign in to accept and join the rotation.`,
      cta: { label: "View invitation", href: appUrl("/circles") },
    }),
    text: `${inviter} invited you to join "${circle.name}" on MoolaHub. Visit ${appUrl("/circles")} to accept.`,
  });

  const [invitedUser] = await db.select().from(usersTable).where(eq(usersTable.email, email));
  if (invitedUser) {
    await notify(invitedUser.id, {
      type: "invite",
      title: "Circle invitation",
      body: `${inviter} invited you to join "${circle.name}".`,
      link: "/circles",
    });
  }
}

export async function listInvitesForUser(email: string) {
  const invites = await db.query.circleInvitesTable.findMany({
    where: and(eq(circleInvitesTable.email, email.toLowerCase()), eq(circleInvitesTable.status, "pending")),
    with: { circle: { with: { members: true, createdBy: true } } },
    orderBy: desc(circleInvitesTable.createdAt),
  });
  return invites.map((i) => ({
    id: i.id,
    circleName: i.circle.name,
    inviterName: i.circle.createdBy.name,
    contributionCents: i.circle.contributionCents,
    frequency: i.circle.frequency,
  }));
}

export async function acceptInvite(userId: string, userEmail: string, inviteId: string) {
  const invite = await db.query.circleInvitesTable.findFirst({
    where: eq(circleInvitesTable.id, inviteId),
    with: { circle: { with: { members: true } } },
  });
  if (!invite || invite.status !== "pending") throw new Error("Invitation not found.");
  if (invite.email !== userEmail.toLowerCase()) throw new Error("This invitation isn't for you.");
  if (invite.circle.status !== "forming") throw new Error("This circle has already started.");
  if (invite.circle.members.some((m) => m.userId === userId)) {
    await db
      .update(circleInvitesTable)
      .set({ status: "accepted" })
      .where(eq(circleInvitesTable.id, inviteId));
    return invite.circleId;
  }
  const nextPos = invite.circle.members.length + 1;
  await db.insert(circleMembersTable).values({
    circleId: invite.circleId,
    userId,
    position: nextPos,
    payoutRound: nextPos,
  });
  // Rotation rounds track member count; accumulation rounds are fixed at creation.
  if (invite.circle.type !== "accumulation") {
    await db.update(circlesTable).set({ totalRounds: nextPos }).where(eq(circlesTable.id, invite.circleId));
  }
  await db.update(circleInvitesTable).set({ status: "accepted" }).where(eq(circleInvitesTable.id, inviteId));

  const [accepter] = await db
    .select({ name: usersTable.name })
    .from(usersTable)
    .where(eq(usersTable.id, userId));
  await notify(
    invite.circle.createdById,
    {
      type: "invite_accepted",
      title: "New circle member",
      body: `${accepter?.name ?? "Someone"} joined "${invite.circle.name}".`,
      link: `/circles/${invite.circleId}`,
    },
    { email: true },
  );
  return invite.circleId;
}

export async function declineInvite(userEmail: string, inviteId: string) {
  const [invite] = await db
    .select()
    .from(circleInvitesTable)
    .where(eq(circleInvitesTable.id, inviteId));
  if (!invite || invite.email !== userEmail.toLowerCase()) throw new Error("Invitation not found.");
  await db.update(circleInvitesTable).set({ status: "declined" }).where(eq(circleInvitesTable.id, inviteId));
}

/** Creator locks the rotation and activates the circle (rounds = members). */
export async function startCircle(userId: string, circleId: string) {
  const circle = await db.query.circlesTable.findFirst({
    where: and(eq(circlesTable.id, circleId), eq(circlesTable.createdById, userId)),
    with: { members: { with: { user: { with: { wallet: true } } } } },
  });
  if (!circle) throw new Error("Only the creator can start this circle.");
  if (circle.status !== "forming") throw new Error("This circle has already started.");
  if (circle.members.length < 2) throw new Error("Invite at least one more member first.");

  let startUpdate: Record<string, unknown>;
  if (circle.type === "accumulation") {
    // Accumulation stays ledger-only: rounds and payout were fixed at creation.
    startUpdate = { status: "active", currentRound: 1, startDate: new Date() };
  } else {
    // Rotation: lock rounds to the final member count, then deploy the on-chain
    // Susu escrow so contributions and payouts settle through the real contract.
    // Members are passed in payout-round order so the escrow's positional
    // settlement matches our schedule. If deployment can't happen (no platform
    // key / RPC down / a member lacks a wallet) we fall back to ledger-only so
    // the circle still runs — contractAddress stays null and contributions skip
    // the on-chain rail.
    const totalRounds = circle.members.length;
    const potCents = circle.contributionCents * totalRounds;
    const orderedMembers = [...circle.members].sort((a, b) => a.payoutRound - b.payoutRound);
    const memberAddresses = orderedMembers.map(
      (m) => (m.user as { wallet?: { address: string } | null }).wallet?.address ?? "",
    );

    let contractAddress: string | null = null;
    let payoutCents = potCents;
    if (onchainEnabled()) {
      const roundDurationSecs = (INTERVAL_DAYS[circle.frequency] ?? 30) * 86_400;
      const deployed = await deployCircleEscrow({
        circleId: circle.id,
        contributionCents: circle.contributionCents,
        members: memberAddresses,
        roundDurationSecs,
        gracePeriodSecs: GRACE_PERIOD_DAYS * 86_400,
      });
      if (deployed.status === "confirmed") {
        contractAddress = deployed.escrow;
        // On-chain the escrow takes the platform fee out of each payout, so the
        // recipient nets pot - fee. Mirror that in the stored payout estimate.
        payoutCents = potCents - feeCentsOf(potCents);
      }
    }

    startUpdate = {
      status: "active",
      currentRound: 1,
      totalRounds,
      payoutCents,
      contractAddress,
      startDate: new Date(),
    };
  }
  // Compare-and-set on `status='forming'`: the read-then-deploy above is a TOCTOU
  // window (escrow deployment can take seconds), so two concurrent starts could
  // otherwise both write — one with a confirmed contractAddress, the other with a
  // null fallback that overwrites it. Conditioning the write on the still-forming
  // status means only the first writer wins; a loser matches 0 rows and is a
  // no-op. The factory keys escrows by circleId and returns the existing one, so
  // a duplicate deploy is harmless and both writers carry the same address.
  const activated = await db
    .update(circlesTable)
    .set(startUpdate)
    .where(and(eq(circlesTable.id, circleId), eq(circlesTable.status, "forming")))
    .returning({ id: circlesTable.id });
  if (activated.length === 0) throw new Error("This circle has already started.");
  const others = circle.members.map((m) => m.userId).filter((id) => id !== userId);
  await notifyMany(
    others,
    {
      type: "circle_started",
      title: "Circle started",
      body: `"${circle.name}" is now active — round 1 has begun.`,
      link: `/circles/${circleId}`,
    },
    { email: true },
  );
}
