/**
 * The fee a group shows, in basis points. Display only: it never decides what is charged.
 * Save-together (accumulation) groups never charge a fee: their payout is contribution × rounds
 * and their contract takes no fee parameter.
 */
export function circleFeeBps(
  c: { type: string; targetMembers: number | null; contractAddress: string | null },
  opts: { escrowOn: boolean; feeBps: number },
): number {
  if (c.type === "accumulation") return 0;
  if (c.targetMembers != null) return opts.feeBps;
  return opts.escrowOn && c.contractAddress ? opts.feeBps : 0;
}
