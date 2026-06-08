import { Router, type IRouter } from "express";
import { eq, and } from "drizzle-orm";
import { db, lessonProgressTable } from "@workspace/db";
import { GetDashboardSummaryResponse } from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import { LESSONS } from "../lib/lessons-data";
import { userBalances, userActivity } from "../lib/ledger";
import { listGoals } from "../lib/goals";
import { listCirclesForUser } from "../lib/circles";

const router: IRouter = Router();

router.get("/dashboard/summary", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;

  const bal = await userBalances(user.id);
  const goals = await listGoals(user.id);
  const circles = await listCirclesForUser(user.id);
  const activity = await userActivity(user.id, 5);

  const completedLessons = await db
    .select()
    .from(lessonProgressTable)
    .where(and(eq(lessonProgressTable.userId, user.id), eq(lessonProgressTable.completed, true)));

  const activeGoals = goals
    .filter((g) => g.status === "active")
    .slice(0, 3)
    .map((g) => ({
      id: g.id,
      name: g.name,
      emoji: g.emoji,
      color: g.color,
      targetCents: g.targetCents,
      savedCents: g.savedCents,
      deadline: g.deadline.toISOString(),
      frequency: g.frequency,
      autoSaveCents: g.autoSaveCents ?? null,
      createdAt: g.createdAt.toISOString(),
    }));

  const activeCircles = circles.slice(0, 3).map((c) => ({
    id: c.id,
    name: c.name,
    status: c.status,
    type: c.type,
    frequency: c.frequency,
    contributionCents: c.contributionCents,
    payoutCents: c.payoutCents,
    potCents: c.potCents,
    memberCount: c.memberCount,
    myPayoutRound: c.myPayoutRound,
    currentRound: c.currentRound,
    totalRounds: c.totalRounds,
    nextPayoutDate: c.nextPayoutDate,
  }));

  const recentActivity = activity.map((t) => ({
    id: t.id,
    type: t.type,
    description: t.description,
    amountCents: t.amountCents,
    txHash: t.txHash ?? null,
    onchainStatus: t.onchainStatus,
    createdAt: t.createdAt.toISOString(),
  }));

  const circlePotCents = circles.reduce((sum, c) => sum + c.potCents, 0);

  const upcoming = circles.find((c) => c.nextPayoutDate && c.status === "active");
  const upcomingReminder = upcoming
    ? {
        title: `${upcoming.name} contribution due`,
        amountCents: upcoming.contributionCents,
        dueDate: upcoming.nextPayoutDate!,
      }
    : undefined;

  res.json(
    GetDashboardSummaryResponse.parse({
      availableCents: bal.availableCents,
      totalCents: bal.totalCents,
      goalTotalCents: bal.allocatedCents,
      circlePotCents,
      yieldApy: 4.5,
      recentActivity,
      activeGoals,
      activeCircles,
      lessonsCompleted: completedLessons.length,
      totalLessons: LESSONS.length,
      upcomingReminder,
    }),
  );
});

export default router;
