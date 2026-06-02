import { Router, type IRouter } from "express";
import { eq, desc, and } from "drizzle-orm";
import {
  db,
  walletsTable,
  goalsTable,
  circlesTable,
  circleMembersTable,
  transactionsTable,
  lessonProgressTable,
} from "@workspace/db";
import { GetDashboardSummaryResponse } from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import { LESSONS } from "../lib/lessons-data";

const router: IRouter = Router();

router.get("/dashboard/summary", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;

  const [wallet] = await db.select().from(walletsTable).where(eq(walletsTable.userId, user.id));
  const availableCents = wallet?.availableCents ?? 0;
  const goalAllocatedCents = wallet?.goalAllocatedCents ?? 0;

  const goals = await db
    .select()
    .from(goalsTable)
    .where(and(eq(goalsTable.userId, user.id), eq(goalsTable.status, "active")))
    .limit(3);

  const memberRows = await db
    .select()
    .from(circleMembersTable)
    .where(eq(circleMembersTable.userId, user.id));

  const circleIds = memberRows.map((m) => m.circleId);
  const circles: (typeof circlesTable.$inferSelect)[] = [];
  for (const cid of circleIds.slice(0, 3)) {
    const [c] = await db.select().from(circlesTable).where(eq(circlesTable.id, cid));
    if (c) circles.push(c);
  }

  const circlePotCents = circles.reduce((sum, c) => sum + c.potCents, 0);
  const goalTotalCents = goals.reduce((sum, g) => sum + g.savedCents, 0);
  const totalCents = availableCents + goalAllocatedCents;

  const recentTx = await db
    .select()
    .from(transactionsTable)
    .where(eq(transactionsTable.userId, user.id))
    .orderBy(desc(transactionsTable.createdAt))
    .limit(5);

  const completedLessons = await db
    .select()
    .from(lessonProgressTable)
    .where(and(eq(lessonProgressTable.userId, user.id), eq(lessonProgressTable.completed, true)));

  const circleSummaries = circles.map((c) => {
    const myMember = memberRows.find((m) => m.circleId === c.id);
    return {
      id: c.id,
      name: c.name,
      status: c.status,
      frequency: c.frequency,
      contributionCents: c.contributionCents,
      potCents: c.potCents,
      memberCount: memberRows.filter((m) => m.circleId === c.id).length,
      myPayoutRound: myMember?.payoutRound ?? 0,
      currentRound: c.currentRound,
      totalRounds: c.totalRounds,
      nextPayoutDate: c.nextPayoutDate?.toISOString() ?? null,
    };
  });

  const activeGoalsList = goals.map((g) => ({
    id: g.id,
    name: g.name,
    emoji: g.emoji,
    color: g.color,
    targetCents: g.targetCents,
    savedCents: g.savedCents,
    deadline: g.deadline.toISOString(),
    autoSaveCents: g.autoSaveCents ?? null,
    createdAt: g.createdAt.toISOString(),
  }));

  const recentActivity = recentTx.map((t) => ({
    id: t.id,
    type: t.type,
    description: t.description,
    amountCents: t.amountCents ?? null,
    txHash: t.txHash ?? null,
    onchainStatus: t.onchainStatus,
    createdAt: t.createdAt.toISOString(),
  }));

  const upcomingCircle = circles.find((c) => c.nextPayoutDate);
  const upcomingReminder = upcomingCircle
    ? {
        title: `${upcomingCircle.name} contribution due`,
        amountCents: upcomingCircle.contributionCents,
        dueDate: upcomingCircle.nextPayoutDate!.toISOString(),
      }
    : undefined;

  res.json(
    GetDashboardSummaryResponse.parse({
      availableCents,
      totalCents,
      goalTotalCents,
      circlePotCents,
      yieldApy: 4.5,
      recentActivity,
      activeGoals: activeGoalsList,
      activeCircles: circleSummaries,
      lessonsCompleted: completedLessons.length,
      totalLessons: LESSONS.length,
      upcomingReminder: upcomingReminder ?? undefined,
    })
  );
});

export default router;
