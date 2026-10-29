import { Router, type IRouter } from "express";
import { eq, and } from "drizzle-orm";
import { db, lessonProgressTable } from "@workspace/db";
import { GetDashboardSummaryResponse } from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import { LESSONS } from "../lib/lessons-data";
import { userActivity } from "../lib/ledger";
import { userOnchainBalanceSummary } from "../lib/onchainBalances";
import { listGoals } from "../lib/goals";
import { listCirclesForUser, currentRoundContributions } from "../lib/circles";
import { dashboardGoalJson } from "../lib/goalJson";
import { homeCircles, pickUpcomingPayIn } from "../lib/dashboardView";

const router: IRouter = Router();

router.get("/dashboard/summary", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;

  // Balances sourced from on-chain (when configured) so the dashboard shows the
  // REAL settled balance, not the ledger's optimistic view.
  const bal = await userOnchainBalanceSummary(user.id);
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
    .map(dashboardGoalJson);

  const activeCircles = homeCircles(circles).map((c) => ({
    id: c.id,
    name: c.name,
    status: c.status,
    type: c.type,
    frequency: c.frequency,
    contributionCents: c.contributionCents,
    payoutCents: c.payoutCents,
    potCents: c.potCents,
    memberCount: c.memberCount,
    targetMembers: c.targetMembers,
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

  // The caller's next pay-in still due, with no date (a round advances when
  // everyone has paid). null means nothing is owed, never "could not tell".
  const rows = await currentRoundContributions(circles);
  const upcomingPayIn = pickUpcomingPayIn(user.id, circles, rows);

  res.json(
    GetDashboardSummaryResponse.parse({
      availableCents: bal.availableCents,
      totalCents: bal.totalCents,
      goalTotalCents: bal.allocatedCents,
      pendingCents: bal.pendingCents,
      balanceUnavailable: bal.balanceUnavailable,
      circlePotCents,
      recentActivity,
      activeGoals,
      activeCircles,
      lessonsCompleted: completedLessons.length,
      totalLessons: LESSONS.length,
      upcomingReminder,
      upcomingPayIn,
    }),
  );
});

export default router;
