/**
 * Demo domain data for the MoolaHub web app.
 *
 * Conventions (mirrors CLAUDE.md golden rules):
 *  - All money is stored as INTEGER cents (1/100 USDC). Never floats.
 *  - On-chain references (`txHash`) stand in for Stellar/Soroban operations;
 *    in production these resolve to a block explorer (chain is the source of truth).
 *  - Goals are accounting allocations over ONE non-custodial wallet balance,
 *    NOT separate on-chain accounts.
 */

export const CURRENCY = "USDC";

export type KycStatus = "verified" | "pending" | "unstarted";

export interface CurrentUser {
  name: string;
  email: string;
  walletAddress: string;
  kyc: KycStatus;
  memberSince: string;
}

export const currentUser: CurrentUser = {
  name: "Ama Mensah",
  email: "ama@moolahub.io",
  walletAddress: "GBHK4QZ7M3UYV2XK6F9N4ELZ5RJ8WQ7D2C5T1AP3SVB9MOOLAHUBXYZ",
  kyc: "verified",
  memberSince: "2025-09-12",
};

export interface Wallet {
  /** Total spendable balance in cents (USDC) */
  balanceCents: number;
  /** Sum currently allocated to goals (subset of balance) */
  allocatedCents: number;
  /** Estimated yield earned to date via Blend lending */
  yieldEarnedCents: number;
  /** Current annualised yield rate, e.g. 0.041 = 4.1% */
  yieldApy: number;
}

export const wallet: Wallet = {
  balanceCents: 482_650,
  allocatedCents: 312_000,
  yieldEarnedCents: 7_420,
  yieldApy: 0.041,
};

export interface Goal {
  id: string;
  name: string;
  emoji: string;
  targetCents: number;
  savedCents: number;
  deadline: string;
  autoSaveCents: number | null; // weekly auto-save, null if off
  color: "jade" | "amber" | "sky";
}

export const goals: Goal[] = [
  {
    id: "rent",
    name: "Rent buffer",
    emoji: "🏠",
    targetCents: 200_000,
    savedCents: 164_000,
    deadline: "2026-08-01",
    autoSaveCents: 5_000,
    color: "jade",
  },
  {
    id: "laptop",
    name: "New laptop",
    emoji: "💻",
    targetCents: 120_000,
    savedCents: 86_000,
    deadline: "2026-07-15",
    autoSaveCents: 4_000,
    color: "sky",
  },
  {
    id: "emergency",
    name: "Emergency fund",
    emoji: "🛟",
    targetCents: 150_000,
    savedCents: 62_000,
    deadline: "2026-12-31",
    autoSaveCents: 3_000,
    color: "amber",
  },
];

export type CircleStatus = "active" | "forming" | "completed";
export type MemberPayoutState = "paid" | "upcoming" | "current";

export interface CircleMember {
  name: string;
  position: number;
  state: MemberPayoutState;
  payoutDate: string;
  isYou?: boolean;
}

export interface ContributionRecord {
  id: string;
  round: number;
  date: string;
  amountCents: number;
  member: string;
  txHash: string;
  status: "confirmed" | "pending";
}

export interface Circle {
  id: string;
  name: string;
  status: CircleStatus;
  contributionCents: number; // per member, per round
  frequency: "weekly" | "biweekly" | "monthly";
  members: CircleMember[];
  totalRounds: number;
  currentRound: number;
  nextContributionDate: string;
  potCents: number; // payout per round (contribution * members)
  contractAddress: string;
  history: ContributionRecord[];
}

export const circles: Circle[] = [
  {
    id: "market-women",
    name: "Makola Market Circle",
    status: "active",
    contributionCents: 5_000,
    frequency: "weekly",
    totalRounds: 8,
    currentRound: 3,
    nextContributionDate: "2026-06-05",
    potCents: 40_000,
    contractAddress: "CDLZ7Q4...SUSU8X",
    members: [
      { name: "Esi Boateng", position: 1, state: "paid", payoutDate: "2026-05-15" },
      { name: "Kofi Asante", position: 2, state: "paid", payoutDate: "2026-05-22" },
      { name: "Ama Mensah", position: 3, state: "current", payoutDate: "2026-06-05", isYou: true },
      { name: "Yaw Darko", position: 4, state: "upcoming", payoutDate: "2026-06-12" },
      { name: "Adwoa Owusu", position: 5, state: "upcoming", payoutDate: "2026-06-19" },
      { name: "Kwame Nkrumah", position: 6, state: "upcoming", payoutDate: "2026-06-26" },
      { name: "Akua Sarpong", position: 7, state: "upcoming", payoutDate: "2026-07-03" },
      { name: "Fiifi Tetteh", position: 8, state: "upcoming", payoutDate: "2026-07-10" },
    ],
    history: [
      { id: "c1", round: 1, date: "2026-05-15", amountCents: 5_000, member: "You", txHash: "f3a91c", status: "confirmed" },
      { id: "c2", round: 2, date: "2026-05-22", amountCents: 5_000, member: "You", txHash: "a7b22d", status: "confirmed" },
      { id: "c3", round: 3, date: "2026-05-29", amountCents: 5_000, member: "You", txHash: "9e44f1", status: "confirmed" },
    ],
  },
  {
    id: "family",
    name: "Family Savings",
    status: "active",
    contributionCents: 10_000,
    frequency: "monthly",
    totalRounds: 6,
    currentRound: 2,
    nextContributionDate: "2026-06-28",
    potCents: 60_000,
    contractAddress: "CDFAM92...SUSU2K",
    members: [
      { name: "Ama Mensah", position: 1, state: "paid", payoutDate: "2026-04-28", isYou: true },
      { name: "Kojo Mensah", position: 2, state: "current", payoutDate: "2026-05-28" },
      { name: "Abena Mensah", position: 3, state: "upcoming", payoutDate: "2026-06-28" },
      { name: "Nana Mensah", position: 4, state: "upcoming", payoutDate: "2026-07-28" },
      { name: "Efua Mensah", position: 5, state: "upcoming", payoutDate: "2026-08-28" },
      { name: "Kweku Mensah", position: 6, state: "upcoming", payoutDate: "2026-09-28" },
    ],
    history: [
      { id: "f1", round: 1, date: "2026-04-28", amountCents: 10_000, member: "You", txHash: "11ab3c", status: "confirmed" },
      { id: "f2", round: 2, date: "2026-05-28", amountCents: 10_000, member: "You", txHash: "55cd7e", status: "confirmed" },
    ],
  },
  {
    id: "tech-savers",
    name: "Accra Tech Savers",
    status: "forming",
    contributionCents: 25_000,
    frequency: "monthly",
    totalRounds: 5,
    currentRound: 0,
    nextContributionDate: "2026-06-30",
    potCents: 125_000,
    contractAddress: "—",
    members: [
      { name: "Ama Mensah", position: 1, state: "upcoming", payoutDate: "2026-06-30", isYou: true },
      { name: "Selorm Agbley", position: 2, state: "upcoming", payoutDate: "2026-07-30" },
      { name: "Nana Yaa", position: 3, state: "upcoming", payoutDate: "2026-08-30" },
    ],
    history: [],
  },
];

export interface ActivityItem {
  id: string;
  type: "deposit" | "contribution" | "payout" | "yield" | "goal" | "withdrawal";
  title: string;
  subtitle: string;
  amountCents: number; // positive = in, negative = out
  date: string;
  txHash?: string;
}

export const activity: ActivityItem[] = [
  { id: "a1", type: "yield", title: "Yield earned", subtitle: "Blend lending pool", amountCents: 310, date: "2026-06-01T08:02:00Z", txHash: "yld8a2" },
  { id: "a2", type: "contribution", title: "Makola Market Circle", subtitle: "Round 3 contribution", amountCents: -5_000, date: "2026-05-29T14:20:00Z", txHash: "9e44f1" },
  { id: "a3", type: "deposit", title: "Deposit via Yellowcard", subtitle: "GHS → USDC · fee-free", amountCents: 50_000, date: "2026-05-28T10:11:00Z", txHash: "dep3k9" },
  { id: "a4", type: "contribution", title: "Family Savings", subtitle: "Round 2 contribution", amountCents: -10_000, date: "2026-05-28T09:00:00Z", txHash: "55cd7e" },
  { id: "a5", type: "goal", title: "Auto-save → Rent buffer", subtitle: "Weekly allocation", amountCents: -5_000, date: "2026-05-26T06:00:00Z" },
  { id: "a6", type: "payout", title: "Family Savings payout", subtitle: "Round 1 · you received the pot", amountCents: 60_000, date: "2026-04-28T12:00:00Z", txHash: "11ab3c" },
];

export interface Reminder {
  id: string;
  title: string;
  detail: string;
  dueDate: string;
  amountCents: number;
  kind: "contribution" | "autosave" | "payout";
}

export const reminders: Reminder[] = [
  { id: "r1", title: "Makola Market Circle", detail: "Round 4 contribution due", dueDate: "2026-06-05", amountCents: 5_000, kind: "contribution" },
  { id: "r2", title: "Rent buffer auto-save", detail: "Weekly allocation", dueDate: "2026-06-02", amountCents: 5_000, kind: "autosave" },
  { id: "r3", title: "Family Savings", detail: "Round 3 contribution due", dueDate: "2026-06-28", amountCents: 10_000, kind: "contribution" },
];

export interface Lesson {
  slug: string;
  title: string;
  summary: string;
  minutes: number;
  level: "Beginner" | "Intermediate";
  category: string;
  emoji: string;
  completed: boolean;
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
    completed: true,
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
    summary: "How much to set aside, where to keep it, and how to get there without feeling the pinch.",
    minutes: 5,
    level: "Beginner",
    category: "Saving",
    emoji: "🛟",
    completed: false,
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
    summary: "What APY means, how Blend lending generates yield on USDC, and why it isn't a guaranteed return.",
    minutes: 6,
    level: "Intermediate",
    category: "Growing",
    emoji: "📈",
    completed: false,
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
    summary: "The red flags of fraud — guaranteed returns, urgency, and requests for your secret keys.",
    minutes: 4,
    level: "Beginner",
    category: "Safety",
    emoji: "🛡️",
    completed: false,
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
