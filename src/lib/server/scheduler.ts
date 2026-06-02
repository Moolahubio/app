import "server-only";
import { db } from "@/lib/db";
import { userBalances, goalBalances } from "./ledger";
import { allocateToGoal } from "./goals";
import { notify } from "./notifications";
import { formatMoney } from "@/lib/utils";

const WEEK_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * Execute weekly goal auto-saves. Idempotent: a goal only auto-saves once per
 * 7 days (tracked on Goal.lastAutoSaveAt), and never beyond its target or the
 * user's available balance.
 */
export async function runAutoSaves(now = new Date()) {
  const goals = await db.goal.findMany({ where: { autoSaveCents: { not: null } } });
  let executed = 0;
  let movedCents = 0;

  for (const g of goals) {
    if (g.lastAutoSaveAt && now.getTime() - g.lastAutoSaveAt.getTime() < WEEK_MS) continue;

    const saved = (await goalBalances(g.userId))[g.id] ?? 0;
    if (saved >= g.targetCents) {
      // Goal already met — stamp so we don't recheck until next week.
      await db.goal.update({ where: { id: g.id }, data: { lastAutoSaveAt: now } });
      continue;
    }

    const { availableCents } = await userBalances(g.userId);
    const amount = Math.min(g.autoSaveCents!, g.targetCents - saved, availableCents);
    if (amount <= 0) continue; // not enough funds; retry next run (don't stamp)

    await allocateToGoal(g.userId, g.id, amount); // moves money + notifies
    await db.goal.update({ where: { id: g.id }, data: { lastAutoSaveAt: now } });
    executed++;
    movedCents += amount;
  }
  return { executed, movedCents };
}

/**
 * Send contribution reminders for active circles. Idempotent per round via
 * CircleMember.remindedRound, so repeated runs never spam.
 */
export async function runContributionReminders() {
  const circles = await db.circle.findMany({
    where: { status: "active" },
    include: { members: true, contributions: true },
  });
  let sent = 0;

  for (const c of circles) {
    for (const m of c.members) {
      if (m.remindedRound >= c.currentRound) continue;

      const done = c.contributions.some(
        (x) => x.userId === m.userId && x.round === c.currentRound,
      );
      if (done) {
        await db.circleMember.update({
          where: { id: m.id },
          data: { remindedRound: c.currentRound },
        });
        continue;
      }

      await notify(
        m.userId,
        {
          type: "system",
          title: `Contribution due: ${c.name}`,
          body: `Round ${c.currentRound} · ${formatMoney(c.contributionCents)} is due. Tap to pay.`,
          link: `/circles/${c.id}`,
        },
        { email: true },
      );
      await db.circleMember.update({
        where: { id: m.id },
        data: { remindedRound: c.currentRound },
      });
      sent++;
    }
  }
  return { sent };
}

export async function runDailyJobs() {
  const autosave = await runAutoSaves();
  const reminders = await runContributionReminders();
  return { autosave, reminders, at: new Date().toISOString() };
}
