/**
 * Pure choices behind the dashboard summary. No imports, so they are unit-tested
 * without a database.
 */

/** Groups for Home: active first, then any other status except completed (today: forming),
 *  each in the given order (newest created first); completed groups are left out. */
export function homeCircles<T extends { status: string }>(circles: T[], limit = 3): T[] {
  const active = circles.filter((c) => c.status === "active");
  const rest = circles.filter((c) => c.status !== "active" && c.status !== "completed");
  return [...active, ...rest].slice(0, limit);
}

export type PayInCandidate = {
  id: string; name: string; status: string; contributionCents: number;
  currentRound: number; totalRounds: number; memberCount: number; nextPayoutDate: string | null;
};
export type RoundContribution = { circleId: string; round: number; userId: string };
export type UpcomingPayIn = {
  circleId: string; circleName: string; amountCents: number; round: number; totalRounds: number;
};

/**
 * The caller's next pay-in that is still due, or null.
 * Due = an active group (round >= 1) with no contribution row from the caller for its current round.
 * `circles` arrives newest created first (listCirclesForUser).
 * Order: (1) groups where every other member has already paid this round (the round, and a
 * take-turns payout, waits on the caller); (2) the round open longest (earliest nominal round
 * start, used for ordering only and never sent); (3) the older group (a later position in `circles`).
 */
export function pickUpcomingPayIn(
  userId: string, circles: PayInCandidate[], rows: RoundContribution[],
): UpcomingPayIn | null {
  const owed = circles
    .map((c, index) => ({ c, index }))
    .filter(({ c }) => c.status === "active" && c.currentRound >= 1)
    .map(({ c, index }) => {
      const round = rows.filter((r) => r.circleId === c.id && r.round === c.currentRound);
      const mine = round.some((r) => r.userId === userId);
      const others = round.filter((r) => r.userId !== userId).length;
      const start = c.nextPayoutDate ? Date.parse(c.nextPayoutDate) : NaN;
      return { c, index, mine, lastToPay: others >= c.memberCount - 1, start };
    })
    .filter((g) => !g.mine);
  if (!owed.length) return null;

  owed.sort((a, b) => {
    if (a.lastToPay !== b.lastToPay) return a.lastToPay ? -1 : 1;
    const aKnown = Number.isFinite(a.start);
    const bKnown = Number.isFinite(b.start);
    if (aKnown !== bKnown) return aKnown ? -1 : 1;
    if (aKnown && a.start !== b.start) return a.start - b.start;
    return b.index - a.index;
  });

  const { c } = owed[0];
  return {
    circleId: c.id,
    circleName: c.name,
    amountCents: c.contributionCents,
    round: c.currentRound,
    totalRounds: c.totalRounds,
  };
}
