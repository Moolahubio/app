import "server-only";
import { db } from "@/lib/db";

const INTERVAL_DAYS: Record<string, number> = { weekly: 7, biweekly: 14, monthly: 30 };

export interface Reminder {
  id: string;
  title: string;
  detail: string;
  dueDate: Date;
  amountCents: number;
  kind: "contribution" | "autosave";
}

function addInterval(start: Date, frequency: string, rounds: number) {
  const d = new Date(start);
  d.setDate(d.getDate() + INTERVAL_DAYS[frequency] * rounds);
  return d;
}

/**
 * Derived payment reminders: outstanding circle contributions for the current
 * round, plus weekly goal auto-saves. Sorted soonest-first.
 */
export async function getReminders(userId: string): Promise<Reminder[]> {
  const reminders: Reminder[] = [];

  const circles = await db.circle.findMany({
    where: { status: "active", members: { some: { userId } } },
    include: { contributions: { where: { userId } } },
  });
  for (const c of circles) {
    const done = c.contributions.some((x) => x.round === c.currentRound);
    if (!done) {
      reminders.push({
        id: `c-${c.id}`,
        title: c.name,
        detail: `Round ${c.currentRound} contribution due`,
        dueDate: addInterval(c.startDate, c.frequency, Math.max(0, c.currentRound - 1)),
        amountCents: c.contributionCents,
        kind: "contribution",
      });
    }
  }

  const goals = await db.goal.findMany({ where: { userId, autoSaveCents: { not: null } } });
  const now = new Date();
  for (const g of goals) {
    const due = new Date(now);
    due.setDate(due.getDate() + 2);
    reminders.push({
      id: `g-${g.id}`,
      title: `${g.name} auto-save`,
      detail: "Weekly allocation",
      dueDate: due,
      amountCents: g.autoSaveCents ?? 0,
      kind: "autosave",
    });
  }

  return reminders.sort((a, b) => a.dueDate.getTime() - b.dueDate.getTime());
}
