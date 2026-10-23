/**
 * Lessons about the plumbing (digital dollars, networks, crypto transfers) form
 * an opt-in "Under the hood" track: listed only when Technical details is on.
 * Everyday lessons (circles, goals, emergency funds) are always shown.
 */
const UNDER_THE_HOOD = new Set(["crypto", "remittance"]);

export function isUnderTheHood(category: string): boolean {
  return UNDER_THE_HOOD.has(category);
}

/** The lessons a user should see in lists and "next lesson" links. */
export function visibleLessons<T extends { category: string }>(lessons: T[], technical: boolean): T[] {
  return technical ? lessons : lessons.filter((l) => !isUnderTheHood(l.category));
}
