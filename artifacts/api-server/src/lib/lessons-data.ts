export interface LessonBodySection {
  heading: string;
  text: string;
}

export interface LessonDef {
  slug: string;
  title: string;
  summary: string;
  minutes: number;
  level: string;
  category: string;
  emoji: string;
  body: LessonBodySection[];
  takeaways: string[];
}

export const LESSONS: LessonDef[] = [
  {
    slug: "what-is-a-susu",
    title: "What is a Susu?",
    summary: "Learn how rotating savings groups have helped communities across Africa and the diaspora build wealth for generations.",
    minutes: 5,
    level: "beginner",
    category: "circles",
    emoji: "🤝",
    body: [
      {
        heading: "The Power of Collective Saving",
        text: "A Susu (also called Esusu, Tontine, or Chit Fund depending on the culture) is a rotating savings and credit association. A group of trusted people each contribute a fixed amount at regular intervals, and each period one member receives the entire pot."
      },
      {
        heading: "How It Works",
        text: "Imagine 10 friends each contribute $100 every month. Each month, one person receives $1,000. After 10 months, everyone has both contributed $1,000 and received $1,000 — but the value is in receiving a lump sum you could not have saved alone in one month."
      },
      {
        heading: "Why It Works",
        text: "The social accountability of the group keeps everyone disciplined. You save not just for yourself, but for your circle. This peer accountability has made Susus more effective than many formal savings products for communities that value collective responsibility."
      }
    ],
    takeaways: [
      "A Susu is a rotating savings group where members take turns receiving the total pot",
      "Lump sums are powerful for major purchases, emergencies, and investment",
      "Social accountability helps members stay disciplined about saving",
      "MoolaHub brings Susu circles on-chain for transparency and trust"
    ]
  },
  {
    slug: "understanding-usdc",
    title: "What is USDC?",
    summary: "USDC is a dollar-pegged digital currency built for speed and transparency. Learn why MoolaHub uses it for savings.",
    minutes: 4,
    level: "beginner",
    category: "crypto",
    emoji: "💵",
    body: [
      {
        heading: "What is USDC?",
        text: "USDC (USD Coin) is a stablecoin — a cryptocurrency whose value is pegged 1:1 to the US dollar. Unlike Bitcoin, 1 USDC always equals $1.00. It is issued by Circle, a regulated financial company, with dollar reserves fully audited and verified."
      },
      {
        heading: "Why USDC on Monad?",
        text: "Monad is a high-performance, EVM-compatible blockchain that is fast, cheap, and energy-efficient. Sending USDC on Monad costs fractions of a cent and settles in about a second — compared to traditional wire transfers that can take days and cost $25–$50."
      },
      {
        heading: "Is It Safe?",
        text: "USDC is one of the most regulated and trusted stablecoins in the world. Every USDC is backed by actual dollars held in regulated financial institutions. MoolaHub is non-custodial — meaning your funds are always in your own wallet, not held by us."
      }
    ],
    takeaways: [
      "USDC is a digital dollar — 1 USDC = $1.00, always",
      "It runs on the Monad blockchain: fast, cheap, and transparent",
      "MoolaHub is non-custodial — you control your funds at all times",
      "On-chain transactions are publicly verifiable, adding trust to your circles"
    ]
  },
  {
    slug: "setting-savings-goals",
    title: "Savings goals that actually stick",
    summary: "The science and art of setting savings goals that you actually achieve — and how automation makes it easier.",
    minutes: 6,
    level: "beginner",
    category: "personal-finance",
    emoji: "🎯",
    body: [
      {
        heading: "Why Goals Beat Vague Intentions",
        text: "Research shows that people who write down specific goals with deadlines are 42% more likely to achieve them. The key is moving from 'I want to save more' to 'I will save $3,000 for a laptop by December 31st.'"
      },
      {
        heading: "The SMART Framework for Savings",
        text: "Set Specific goals (what exactly are you saving for?), Measurable targets (how much?), Achievable amounts (realistic given your income), Relevant to your life, and Time-bound with a clear deadline. 'Emergency fund of $2,000 by March' beats 'save for emergencies' every time."
      },
      {
        heading: "Auto-Save: Make It Invisible",
        text: "The most powerful savings tool is automation. When money moves to a goal before you can spend it, you adapt your spending to what's left. MoolaHub's auto-save feature allocates funds to your goals on a schedule — you set it once and the discipline happens automatically."
      }
    ],
    takeaways: [
      "Specific goals with deadlines are dramatically more effective than vague intentions",
      "Use the SMART framework: Specific, Measurable, Achievable, Relevant, Time-bound",
      "Auto-save removes the discipline requirement by moving money before you see it",
      "Multiple focused goals (emergency, holiday, investment) beat one big abstract goal"
    ]
  },
  {
    slug: "building-an-emergency-fund",
    title: "Building an emergency fund",
    summary: "Your emergency fund is the foundation of financial resilience. Here's exactly how to build one, even on a tight budget.",
    minutes: 7,
    level: "beginner",
    category: "personal-finance",
    emoji: "🛡️",
    body: [
      {
        heading: "Why the Emergency Fund Comes First",
        text: "Without an emergency fund, any unexpected expense — a car repair, medical bill, or job loss — forces you into debt. An emergency fund breaks this cycle. It is the single highest-ROI financial move most people can make, because it protects every other financial goal."
      },
      {
        heading: "How Much Do You Need?",
        text: "The standard advice is 3–6 months of essential expenses (rent, food, utilities, minimum debt payments). If you have variable income, aim for 6–12 months. Start with a $500–$1,000 mini emergency fund to handle small crises, then build from there."
      },
      {
        heading: "Where to Keep It",
        text: "Your emergency fund should be liquid (instantly accessible), separate from spending money (so you're not tempted), and stable (not in stocks). A savings goal on MoolaHub keeps it earmarked and separate. Once you have it, resist the urge to 'invest' it — its job is insurance, not growth."
      }
    ],
    takeaways: [
      "An emergency fund is the foundation — build it before investing or aggressive saving",
      "Target 3–6 months of essential expenses (not total income)",
      "Start with a $500–$1,000 mini-fund and build from there",
      "Keep it liquid and separate from your spending money"
    ]
  },
  {
    slug: "understanding-blockchain",
    title: "Blockchain, explained simply",
    summary: "What blockchain actually is, why it matters for savings, and how to think about it without the hype.",
    minutes: 5,
    level: "beginner",
    category: "crypto",
    emoji: "⛓️",
    body: [
      {
        heading: "What is a Blockchain?",
        text: "A blockchain is a shared ledger that nobody controls. Instead of a bank keeping your balance in their private database, a blockchain records every transaction in a public record that thousands of computers around the world each hold a copy of. This makes it nearly impossible to alter or falsify."
      },
      {
        heading: "Why It Matters for Savings Circles",
        text: "Traditional Susus require trust in a person — usually the organizer. If they disappear with the pot, there is no recourse. On-chain Susus use smart contracts: code that automatically distributes funds according to the rules everyone agreed to, with built-in safeguards. Each payout holds back the recipient's own future contributions as collateral inside the contract, so if someone takes their turn and then stops paying in, that collateral covers the members still waiting rather than leaving them stranded."
      },
      {
        heading: "The Monad Blockchain",
        text: "MoolaHub uses Monad — a high-performance, EVM-compatible Layer-1 blockchain. It settles transactions in about a second for fractions of a cent in fees, thanks to parallel execution that lets it handle thousands of transactions per second. It uses proof-of-stake consensus, far more energy-efficient than older blockchains. It is designed for exactly the kind of everyday financial transactions MoolaHub powers."
      }
    ],
    takeaways: [
      "A blockchain is a public, tamper-resistant ledger maintained by thousands of computers",
      "Smart contracts enforce rules automatically — no trusted middleman required",
      "The Monad blockchain is fast, cheap, and designed for everyday financial use",
      "On-chain transparency means your circle's funds can be verified by anyone"
    ]
  },
  {
    slug: "sending-money-internationally",
    title: "Sending money abroad",
    summary: "Compare remittance options and understand why crypto rails are changing the cost of sending money home.",
    minutes: 6,
    level: "intermediate",
    category: "remittance",
    emoji: "🌍",
    body: [
      {
        heading: "The Cost of Traditional Remittances",
        text: "The global average cost of sending $200 internationally is 6.5% — meaning $13 disappears before it reaches family. In some corridors (e.g. US to sub-Saharan Africa), fees can reach 8–10%. The World Bank estimates this costs migrants $40+ billion per year globally."
      },
      {
        heading: "Crypto Rails: A Different Path",
        text: "Sending USDC on Monad costs roughly $0.01–$0.05 regardless of the amount. Send $5 or $5,000 — the cost is the same. The recipient receives funds in seconds and can convert to local currency through local exchanges or peer-to-peer markets."
      },
      {
        heading: "The Practical Reality",
        text: "For crypto remittances to work, the recipient needs a way to convert USDC to local currency. In many African countries, mobile money integration and peer-to-peer USDC markets are growing rapidly. The infrastructure is still maturing, but the trajectory is clear: crypto will fundamentally disrupt remittances."
      }
    ],
    takeaways: [
      "Traditional remittances cost 6–10% in fees — billions wasted annually",
      "USDC transfers on Monad cost pennies regardless of amount",
      "Recipient needs local conversion options — infrastructure is growing",
      "Crypto remittances are a major use case driving blockchain adoption in Africa"
    ]
  }
];
