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
        text: "A Susu (also called Esusu, Tontine, or Chit Fund depending on the culture) is a rotating savings and credit association. A group of trusted people each contribute a fixed amount at regular intervals, and each period one member receives that round's pot."
      },
      {
        heading: "How It Works",
        text: "Imagine 10 friends each contribute $100 every month. Each month, one person receives that month's pot of $1,000, less any fee the circle charges. After 10 months, everyone has paid in and had their turn. The value is in receiving a lump sum you could not have saved alone in one month. On MoolaHub, each circle shows its fee and payout before you join."
      },
      {
        heading: "Why It Works",
        text: "The social accountability of the group keeps everyone disciplined. You save not just for yourself, but for your circle. This peer accountability has made Susus more effective than many formal savings products for communities that value collective responsibility."
      }
    ],
    takeaways: [
      "A Susu is a rotating savings group where members take turns receiving the pot",
      "Lump sums are powerful for major purchases, emergencies, and investment",
      "Social accountability helps members stay disciplined about saving",
      "Every MoolaHub circle shows its rules, fee and payout order up front"
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
        text: "USDC (USD Coin) is a stablecoin: a digital currency designed to keep its value at one US dollar. It is issued by Circle, which backs it with cash and short-term US government securities and publishes regular reserve reports. It is designed to stay at $1.00, but that isn't guaranteed: in March 2023 its price briefly fell below $1 when part of its reserves was stuck at a failed bank."
      },
      {
        heading: "Why a digital dollar?",
        text: "USDC moves over modern payment networks that are fast and cheap. A transfer can cost a fraction of a cent and settle in seconds, compared with international wire transfers that can take days and cost $25 to $50."
      },
      {
        heading: "Is It Safe?",
        text: "USDC is one of the most widely used stablecoins, and Circle reports on its reserves every month. Your MoolaHub balance is held as USDC in an account in your name. Money paid into some group savings circles is held by MoolaHub until it is paid out, and each circle's page says how its money is held. Your balance is not a bank deposit and is not insured."
      }
    ],
    takeaways: [
      "USDC is a digital dollar designed to stay at $1.00, but that isn't guaranteed",
      "Digital-dollar transfers are fast and cheap compared with wires",
      "Your balance is not a bank deposit and is not insured",
      "Check each circle's page to see how its money is held"
    ]
  },
  {
    slug: "setting-savings-goals",
    title: "Savings goals that actually stick",
    summary: "The science and art of setting savings goals that you actually achieve, and how a simple routine makes it easier.",
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
        heading: "Make It a Routine",
        text: "The most powerful savings tool is a routine. When money moves to a goal right after you get paid, you adapt your spending to what's left. Each MoolaHub goal comes with a contribution plan that suggests a small amount for each day, week or month, and your savings streak nudges you before a period closes. You still move the money yourself, so you stay in control."
      }
    ],
    takeaways: [
      "Specific goals with deadlines are dramatically more effective than vague intentions",
      "Use the SMART framework: Specific, Measurable, Achievable, Relevant, Time-bound",
      "A fixed routine, right after payday, turns saving into a habit",
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
        text: "Traditional Susus require trust in a person, usually the organizer. If they disappear with the pot, there is no recourse. A smart contract is code that can pay out by the rules everyone agreed to, without a middleman. MoolaHub plans to run circles on audited contracts. Until then, some circle money is held by MoolaHub, and each circle's page says how its money is held."
      },
      {
        heading: "Speed and Cost",
        text: "Modern networks settle a transfer in seconds for a fraction of a cent, and proof-of-stake designs use far less energy than older blockchains. You can see which network your balance uses by turning on Technical details in Settings."
      }
    ],
    takeaways: [
      "A blockchain is a public, tamper-resistant ledger maintained by thousands of computers",
      "Smart contracts can enforce rules automatically, once they are audited and live",
      "Modern networks are fast and cheap enough for everyday payments",
      "Check each circle's page to see how its money is held"
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
        text: "Sending USDC over a modern network can cost a few cents whatever the amount, and the recipient receives it in seconds. Turning it into local currency is the hard part: it means a local exchange or a peer-to-peer market, each with its own fees and risks."
      },
      {
        heading: "The Practical Reality",
        text: "For crypto remittances to work, the recipient needs a way to convert USDC to local currency. In many African countries, mobile money integration and peer-to-peer USDC markets are growing rapidly. The infrastructure is still maturing, so compare the total cost, including conversion, before you send."
      }
    ],
    takeaways: [
      "Traditional remittances cost 6–10% in fees — billions wasted annually",
      "Digital-dollar transfers can cost pennies regardless of amount",
      "Recipient needs local conversion options — infrastructure is growing",
      "Crypto remittances are a major use case driving blockchain adoption in Africa"
    ]
  }
];
