import type { GoalHistoryItem } from "./goals";

/**
 * Goal objects as the API sends them. No runtime imports, so it is unit-tested
 * without a database.
 *
 * `balanceUnavailable` is true when the goal's balance read failed: `savedCents`
 * is then a placeholder 0, never a fact, and clients must not show it as one.
 */
export type GoalRow = {
  id: string;
  name: string;
  emoji: string;
  color: string;
  imageUrl: string | null;
  targetCents: number;
  savedCents: number;
  balanceUnavailable?: boolean;
  deadline: Date;
  frequency: string;
  autoSaveCents: number | null;
  createdAt: Date;
  onchain?: boolean;
  vaultAddress?: string | null;
  explorerUrl?: string | null;
  network?: string;
  feeBps?: number;
  history?: GoalHistoryItem[];
};

export function goalToJson(g: GoalRow) {
  return {
    id: g.id,
    name: g.name,
    emoji: g.emoji,
    color: g.color,
    imageUrl: g.imageUrl ?? null,
    targetCents: g.targetCents,
    savedCents: g.savedCents,
    balanceUnavailable: g.balanceUnavailable ?? false,
    deadline: g.deadline.toISOString(),
    frequency: g.frequency,
    autoSaveCents: g.autoSaveCents ?? null,
    createdAt: g.createdAt.toISOString(),
    onchain: g.onchain ?? false,
    vaultAddress: g.vaultAddress ?? null,
    explorerUrl: g.explorerUrl ?? null,
    network: g.network ?? null,
    feeBps: g.feeBps ?? 0,
    history: g.history ?? [],
  };
}

/** The shorter goal object on the dashboard's `activeGoals`. */
export function dashboardGoalJson(g: GoalRow) {
  return {
    id: g.id,
    name: g.name,
    emoji: g.emoji,
    color: g.color,
    targetCents: g.targetCents,
    savedCents: g.savedCents,
    balanceUnavailable: g.balanceUnavailable ?? false,
    deadline: g.deadline.toISOString(),
    frequency: g.frequency,
    autoSaveCents: g.autoSaveCents ?? null,
    createdAt: g.createdAt.toISOString(),
  };
}
