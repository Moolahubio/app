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
import { onchainEnabled, platformAddress } from "./chain";
import { enqueueOnchainTransfer, kickReconciler } from "./settlement";
import { sendEmail, brandedEmail, appUrl } from "./email";
import { notify, notifyMany } from "./notifications";
import { formatMoney } from "./money";

const INTERVAL_DAYS: Record<string, number> = { weekly: 7, biweekly: 14, monthly: 30 };

function addInterval(start: Date | null, frequency: string, rounds: number): Date {
  const d = new Date(start ?? Date.now());
  d.setDate(d.getDate() + (INTERVAL_DAYS[frequency] ?? 30) * rounds);
  return d;
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
  input: { name: string; contributionCents: number; frequency: string; memberEmails?: string[] },
) {
  if (!input.name?.trim()) throw new Error("Circle name is required.");
  if (input.contributionCents <= 0) throw new Error("Enter a contribution amount.");
  const [circle] = await db
    .insert(circlesTable)
    .values({
      name: input.name.trim(),
      createdById: userId,
      contributionCents: input.contributionCents,
      frequency: input.frequency || "monthly",
      status: "forming",
      currentRound: 0,
      totalRounds: 1,
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
      frequency: c.frequency,
      contributionCents: c.contributionCents,
      potCents: c.contributionCents * memberCount,
      memberCount,
      myPayoutRound: me?.payoutRound ?? 0,
      currentRound: c.currentRound,
      totalRounds: c.totalRounds,
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
    frequency: c.frequency,
    contributionCents: c.contributionCents,
    potCents: c.contributionCents * memberCount,
    memberCount,
    totalRounds: c.totalRounds,
    currentRound: c.currentRound,
    startDate: c.startDate ? c.startDate.toISOString() : null,
    contractAddress: c.contractAddress,
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

  // On-chain settlement is member wallet → platform escrow. Resolve the escrow
  // address before the tx; null disables on-chain for this contribution.
  const escrow = onchainEnabled() ? platformAddress() : null;

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
      tx,
    });
    if (escrow) {
      await enqueueOnchainTransfer(
        {
          transactionId: t.id,
          contributionId: reserved[0].id,
          kind: "contribution",
          sourceUserId: userId,
          toAddress: escrow,
          amountCents: circle.contributionCents,
          memo: `susu:${circleId}`,
        },
        tx,
      );
    }
    return { txn: t, contributionId: reserved[0].id };
  });

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

  await maybeProcessPayout(circleId, round);
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

    // Payout is platform escrow → recipient wallet, settled out of band. Booked
    // "pending" and enqueued atomically with the ledger move; the reconciler
    // settles it on-chain (never silently ledger-only).
    const recipientWallet = (recipient.user as { wallet?: { address: string } | null }).wallet;
    const canSettle = onchainEnabled() && !!recipientWallet;
    await db.transaction(async (tx) => {
      const t = await transfer({
        type: "payout",
        description: `${circle.name} · round ${round} payout`,
        userId: recipient.userId,
        fromKey: acct.pool(circleId),
        toKey: acct.wallet(recipient.userId),
        amountCents: potCents,
        onchain: canSettle ? { onchainStatus: "pending" } : { onchainStatus: "none" },
        requireSufficientFrom: true,
        tx,
      });
      if (canSettle && recipientWallet) {
        await enqueueOnchainTransfer(
          {
            transactionId: t.id,
            kind: "payout",
            sourceUserId: null,
            toAddress: recipientWallet.address,
            amountCents: potCents,
            memo: `payout:${circleId}`,
          },
          tx,
        );
      }
    });
    if (canSettle) kickReconciler();
    await notify(
      recipient.userId,
      {
        type: "payout",
        title: "You received the pot! 🎉",
        body: `${formatMoney(potCents)} from "${circle.name}" landed in your wallet.`,
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
  await db.update(circlesTable).set({ totalRounds: nextPos }).where(eq(circlesTable.id, invite.circleId));
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
    with: { members: true },
  });
  if (!circle) throw new Error("Only the creator can start this circle.");
  if (circle.status !== "forming") throw new Error("This circle has already started.");
  if (circle.members.length < 2) throw new Error("Invite at least one more member first.");
  await db
    .update(circlesTable)
    .set({
      status: "active",
      currentRound: 1,
      totalRounds: circle.members.length,
      startDate: new Date(),
    })
    .where(eq(circlesTable.id, circleId));
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
