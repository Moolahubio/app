import { Router, type IRouter } from "express";
import { eq, and } from "drizzle-orm";
import {
  db,
  circlesTable,
  circleMembersTable,
  circleInvitesTable,
  usersTable,
  walletsTable,
  transactionsTable,
  notificationsTable,
} from "@workspace/db";
import {
  CreateCircleBody,
  InviteToCircleBody,
  GetCircleParams,
  InviteToCircleParams,
  StartCircleParams,
  ContributeToCircleParams,
  AcceptInviteParams,
  DeclineInviteParams,
  ListCirclesResponse,
  ListInvitesResponse,
  GetCircleResponse,
} from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";

const router: IRouter = Router();

router.get("/circles", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;

  const memberRows = await db
    .select()
    .from(circleMembersTable)
    .where(eq(circleMembersTable.userId, user.id));

  const result = [];
  for (const m of memberRows) {
    const [circle] = await db.select().from(circlesTable).where(eq(circlesTable.id, m.circleId));
    if (!circle) continue;
    const allMembers = await db
      .select()
      .from(circleMembersTable)
      .where(eq(circleMembersTable.circleId, circle.id));
    result.push({
      id: circle.id,
      name: circle.name,
      status: circle.status,
      frequency: circle.frequency,
      contributionCents: circle.contributionCents,
      potCents: circle.potCents,
      memberCount: allMembers.length,
      myPayoutRound: m.payoutRound,
      currentRound: circle.currentRound,
      totalRounds: circle.totalRounds,
      nextPayoutDate: circle.nextPayoutDate?.toISOString() ?? null,
    });
  }

  res.json(ListCirclesResponse.parse(result));
});

router.get("/circles/invites", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;

  const invites = await db
    .select()
    .from(circleInvitesTable)
    .where(
      and(
        eq(circleInvitesTable.inviteeEmail, user.email),
        eq(circleInvitesTable.status, "pending")
      )
    );

  const result = [];
  for (const inv of invites) {
    const [circle] = await db.select().from(circlesTable).where(eq(circlesTable.id, inv.circleId));
    const [inviter] = await db.select().from(usersTable).where(eq(usersTable.id, inv.inviterId));
    if (!circle || !inviter) continue;
    result.push({
      id: inv.id,
      circleName: circle.name,
      inviterName: inviter.name,
      contributionCents: circle.contributionCents,
      frequency: circle.frequency,
    });
  }

  res.json(ListInvitesResponse.parse(result));
});

router.post("/circles", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = CreateCircleBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: parsed.error.message });
    return;
  }

  const memberEmails: string[] = parsed.data.memberEmails ?? [];
  const totalRounds = memberEmails.length + 1;

  const [circle] = await db
    .insert(circlesTable)
    .values({
      name: parsed.data.name,
      creatorId: user.id,
      contributionCents: parsed.data.contributionCents,
      frequency: parsed.data.frequency,
      totalRounds,
    })
    .returning();

  await db.insert(circleMembersTable).values({
    circleId: circle.id,
    userId: user.id,
    payoutRound: 1,
    state: "active",
  });

  for (let i = 0; i < memberEmails.length; i++) {
    const email = memberEmails[i].toLowerCase();
    const [existingUser] = await db
      .select()
      .from(usersTable)
      .where(eq(usersTable.email, email));

    await db.insert(circleInvitesTable).values({
      circleId: circle.id,
      inviterId: user.id,
      inviteeEmail: email,
      inviteeId: existingUser?.id ?? null,
      status: "pending",
    });
  }

  const memberRows = await db
    .select()
    .from(circleMembersTable)
    .where(eq(circleMembersTable.circleId, circle.id));

  res.status(201).json(
    GetCircleResponse.parse({
      id: circle.id,
      name: circle.name,
      status: circle.status,
      frequency: circle.frequency,
      contributionCents: circle.contributionCents,
      potCents: circle.potCents,
      memberCount: memberRows.length,
      myPayoutRound: 1,
      currentRound: circle.currentRound,
      totalRounds: circle.totalRounds,
      nextPayoutDate: null,
    })
  );
});

router.get("/circles/:id", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = GetCircleParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: params.error.message });
    return;
  }

  const [circle] = await db.select().from(circlesTable).where(eq(circlesTable.id, params.data.id));
  if (!circle) {
    res.status(404).json({ error: "Circle not found" });
    return;
  }

  const memberRows = await db
    .select()
    .from(circleMembersTable)
    .where(eq(circleMembersTable.circleId, circle.id));

  const myMember = memberRows.find((m) => m.userId === user.id);

  const members = [];
  for (const m of memberRows) {
    const [u] = await db.select().from(usersTable).where(eq(usersTable.id, m.userId));
    if (!u) continue;
    members.push({
      id: u.id,
      name: u.name,
      payoutRound: m.payoutRound,
      state: m.state,
      paidOut: m.paidOut,
      contributedThisRound: m.contributedThisRound,
    });
  }

  res.json(
    GetCircleResponse.parse({
      id: circle.id,
      name: circle.name,
      status: circle.status,
      frequency: circle.frequency,
      contributionCents: circle.contributionCents,
      potCents: circle.potCents,
      currentRound: circle.currentRound,
      totalRounds: circle.totalRounds,
      startDate: circle.startDate?.toISOString() ?? null,
      members,
      myContributionStatus: myMember?.contributedThisRound ? "contributed" : "pending",
      myPayoutRound: myMember?.payoutRound ?? null,
    })
  );
});

router.post("/circles/:id/invite", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = InviteToCircleParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: params.error.message });
    return;
  }
  const parsed = InviteToCircleBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: parsed.error.message });
    return;
  }

  const email = parsed.data.email.toLowerCase();
  const [existingUser] = await db.select().from(usersTable).where(eq(usersTable.email, email));

  await db.insert(circleInvitesTable).values({
    circleId: params.data.id,
    inviterId: user.id,
    inviteeEmail: email,
    inviteeId: existingUser?.id ?? null,
    status: "pending",
  });

  res.json({ ok: true });
});

router.post("/circles/:id/start", requireAuth, async (req, res): Promise<void> => {
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = StartCircleParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: params.error.message });
    return;
  }

  await db
    .update(circlesTable)
    .set({ status: "active", currentRound: 1, startDate: new Date() })
    .where(eq(circlesTable.id, params.data.id));

  res.json({ ok: true });
});

router.post("/circles/:id/contribute", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = ContributeToCircleParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: params.error.message });
    return;
  }

  const [circle] = await db.select().from(circlesTable).where(eq(circlesTable.id, params.data.id));
  if (!circle) {
    res.status(404).json({ error: "Circle not found" });
    return;
  }

  const [wallet] = await db.select().from(walletsTable).where(eq(walletsTable.userId, user.id));
  if (!wallet || wallet.availableCents < circle.contributionCents) {
    res.status(400).json({ error: "Insufficient balance" });
    return;
  }

  await db
    .update(walletsTable)
    .set({ availableCents: wallet.availableCents - circle.contributionCents })
    .where(eq(walletsTable.id, wallet.id));

  await db
    .update(circlesTable)
    .set({ potCents: circle.potCents + circle.contributionCents })
    .where(eq(circlesTable.id, circle.id));

  await db
    .update(circleMembersTable)
    .set({ contributedThisRound: true })
    .where(
      and(
        eq(circleMembersTable.circleId, circle.id),
        eq(circleMembersTable.userId, user.id)
      )
    );

  await db.insert(transactionsTable).values({
    userId: user.id,
    type: "circle_contribution",
    description: `Contribution to ${circle.name}`,
    amountCents: circle.contributionCents,
    onchainStatus: "confirmed",
    referenceId: circle.id,
    referenceType: "circle",
  });

  res.json({ ok: true });
});

router.post("/circles/invites/:id/accept", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = AcceptInviteParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: params.error.message });
    return;
  }

  const [invite] = await db
    .select()
    .from(circleInvitesTable)
    .where(eq(circleInvitesTable.id, params.data.id));

  if (!invite) {
    res.status(404).json({ error: "Invite not found" });
    return;
  }

  const existingMembers = await db
    .select()
    .from(circleMembersTable)
    .where(eq(circleMembersTable.circleId, invite.circleId));

  await db.insert(circleMembersTable).values({
    circleId: invite.circleId,
    userId: user.id,
    payoutRound: existingMembers.length + 1,
    state: "active",
  });

  await db
    .update(circleInvitesTable)
    .set({ status: "accepted", inviteeId: user.id })
    .where(eq(circleInvitesTable.id, params.data.id));

  res.json({ ok: true });
});

router.post("/circles/invites/:id/decline", requireAuth, async (req, res): Promise<void> => {
  const rawId = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const params = DeclineInviteParams.safeParse({ id: rawId });
  if (!params.success) {
    res.status(400).json({ error: params.error.message });
    return;
  }

  await db
    .update(circleInvitesTable)
    .set({ status: "declined" })
    .where(eq(circleInvitesTable.id, params.data.id));

  res.json({ ok: true });
});

export default router;
