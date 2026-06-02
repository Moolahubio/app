/**
 * Static lesson content (financial-empowerment curriculum). Per-user completion
 * is tracked in the database (LessonProgress); the content itself lives here.
 */
export interface Lesson {
  slug: string;
  title: string;
  summary: string;
  minutes: number;
  level: "Beginner" | "Intermediate";
  category: string;
  emoji: string;
  body: { heading: string; text: string }[];
  takeaways: string[];
}

export const lessons: Lesson[] = [
  {
    slug: "what-is-susu",
    title: "What is a Susu, and why it works",
    summary:
      "The centuries-old rotating savings tradition — and how MoolaHub makes it transparent and tamper-proof on-chain.",
    minutes: 4,
    level: "Beginner",
    category: "Foundations",
    emoji: "🤝",
    body: [
      {
        heading: "A tradition of trust",
        text: "A Susu (also called a sou-sou, esusu, or tontine) is a rotating savings circle. A group agrees to contribute a fixed amount each round, and each round one member receives the whole pot. By the end, everyone has contributed the same and everyone has received one full payout.",
      },
      {
        heading: "Discipline you can feel",
        text: "Susu works because of social commitment: you save because your circle is counting on you. That gentle accountability helps people reach lump sums — for rent, school fees, or stock — far faster than saving alone.",
      },
      {
        heading: "Where MoolaHub fits in",
        text: "Traditionally, a human collector holds the money — which means trust risk. MoolaHub replaces the collector with an audited Soroban smart contract: contributions and payouts follow rules no single person can change, and every movement is verifiable on the Stellar ledger.",
      },
    ],
    takeaways: [
      "A Susu is a rotating savings circle — fixed contributions, one payout per round.",
      "It turns social trust into savings discipline.",
      "MoolaHub removes the middleman with on-chain verification.",
    ],
  },
  {
    slug: "emergency-fund",
    title: "Building your first emergency fund",
    summary:
      "How much to set aside, where to keep it, and how to get there without feeling the pinch.",
    minutes: 5,
    level: "Beginner",
    category: "Saving",
    emoji: "🛟",
    body: [
      { heading: "Start with one month", text: "Aim first for one month of essential expenses. It's an achievable target that already protects you from most small shocks." },
      { heading: "Automate it", text: "Set a small weekly auto-save toward an Emergency fund goal. Money you don't see is money you don't spend." },
      { heading: "Keep it reachable but separate", text: "An emergency fund should be liquid — but kept apart from daily spending so it isn't quietly drained." },
    ],
    takeaways: [
      "Target one month of expenses first, then grow to 3–6.",
      "Automate small, regular contributions.",
      "Keep it liquid but separate from spending money.",
    ],
  },
  {
    slug: "understanding-yield",
    title: "How your savings can earn yield",
    summary:
      "What APY means, how Blend lending generates yield on USDC, and why it isn't a guaranteed return.",
    minutes: 6,
    level: "Intermediate",
    category: "Growing",
    emoji: "📈",
    body: [
      { heading: "Idle money loses value", text: "Inflation quietly erodes savings that just sit. Earning a modest yield helps your money hold — and grow — its purchasing power." },
      { heading: "Where the yield comes from", text: "On MoolaHub, opted-in balances can be supplied to Blend, an on-chain lending market. Borrowers pay interest, and that interest flows back to you as yield." },
      { heading: "Yield is variable, not a promise", text: "APY moves with supply and demand, and on-chain lending carries smart-contract risk. Yield is opt-in and never guaranteed — only ever save what you can afford to." },
    ],
    takeaways: [
      "APY is an annualised rate — it varies over time.",
      "Yield on MoolaHub comes from on-chain lending via Blend.",
      "It's opt-in and variable, never a guaranteed return.",
    ],
  },
  {
    slug: "spot-a-scam",
    title: "Spotting financial scams",
    summary:
      "The red flags of fraud — guaranteed returns, urgency, and requests for your secret keys.",
    minutes: 4,
    level: "Beginner",
    category: "Safety",
    emoji: "🛡️",
    body: [
      { heading: "If it sounds too good…", text: "Guaranteed high returns with no risk are the oldest lie in finance. Real savings grow steadily, not magically." },
      { heading: "Urgency is a weapon", text: "Scammers manufacture pressure — 'act now or lose out'. Slow down. A legitimate opportunity survives a good night's sleep." },
      { heading: "Never share your keys", text: "MoolaHub is non-custodial: only you control your wallet. No one from MoolaHub will ever ask for your recovery phrase or private key." },
    ],
    takeaways: [
      "Guaranteed returns are a red flag.",
      "Urgency and pressure are manipulation tactics.",
      "Never share your recovery phrase — not even with 'support'.",
    ],
  },
];

export function getLesson(slug: string) {
  return lessons.find((l) => l.slug === slug);
}
