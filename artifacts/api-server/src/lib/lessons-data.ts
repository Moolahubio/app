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
    summary: "How rotating savings groups work, and why communities across Africa and the diaspora have used them for generations.",
    minutes: 5,
    level: "beginner",
    category: "circles",
    emoji: "🤝",
    body: [
      {
        heading: "The power of saving as a group",
        text: "A Susu (also called Esusu, tontine or chit fund, depending on the culture) is a rotating savings and credit association. A group of trusted people each pay in a fixed amount at regular intervals, and each period one member receives that round's pot."
      },
      {
        heading: "How it works",
        text: "Imagine 10 friends each pay in $100 every month. Each month, one person receives that month's pot. After 10 months, everyone has paid in and had their turn. The value is in receiving a lump sum you could not have saved alone in one month. Some groups charge a small fee, added to each pay-in or taken from the pot. On MoolaHub, an invitation shows how much you pay in each round and how often. Once you join, the group's page shows the payout each round and, once the group starts, the payout order."
      },
      {
        heading: "Why it works",
        text: "Knowing that others are counting on you helps everyone keep paying in. You save not just for yourself, but for your group. For many communities, that shared commitment is what makes a Susu work."
      }
    ],
    takeaways: [
      "A Susu is a rotating savings group where members take turns receiving the pot",
      "A lump sum can cover a big purchase or an emergency",
      "Social accountability helps members stay disciplined about saving",
      "On MoolaHub, members see the payout each round and, once the group starts, the payout order"
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
    summary: "How to set savings goals you can reach, and how a simple routine makes them easier.",
    minutes: 6,
    level: "beginner",
    category: "personal-finance",
    emoji: "🎯",
    body: [
      {
        heading: "Why goals beat vague intentions",
        text: "A specific goal with a deadline tells you how much to set aside and lets you check your progress along the way. The key is moving from 'I want to save more' to 'I will save $3,000 for a laptop by December 31.'"
      },
      {
        heading: "The SMART framework for savings",
        text: "Set Specific goals (what exactly are you saving for?), Measurable targets (how much?), Achievable amounts (realistic given your income), Relevant to your life, and Time-bound with a clear deadline. 'Emergency fund of $2,000 by March' is easier to act on than 'save for emergencies'."
      },
      {
        heading: "Make it a routine",
        text: "A routine is one of the most useful savings tools. When money moves to a goal right after you get paid, you adapt your spending to what's left. Each MoolaHub goal comes with a plan that suggests an amount for each day, week or month, starting small and growing gradually, and your savings streak counts how many days, weeks or months in a row you've saved. You still move the money yourself, so you stay in control."
      }
    ],
    takeaways: [
      "Specific goals with deadlines are easier to act on than vague intentions",
      "Use the SMART framework: Specific, Measurable, Achievable, Relevant, Time-bound",
      "A fixed routine, right after payday, turns saving into a habit",
      "A few focused goals (emergency, holiday, school fees) are easier to track than one big goal"
    ]
  },
  {
    slug: "building-an-emergency-fund",
    title: "Building an emergency fund",
    summary: "An emergency fund keeps one surprise from undoing the rest of your plans. Here's how to build one, even on a tight budget.",
    minutes: 7,
    level: "beginner",
    category: "personal-finance",
    emoji: "🛡️",
    body: [
      {
        heading: "Why the emergency fund comes first",
        text: "Without an emergency fund, an unexpected expense, such as a car repair, a medical bill or a lost job, can push you into debt. An emergency fund breaks that cycle and keeps your other goals on track."
      },
      {
        heading: "How much do you need?",
        text: "A common guideline is 3–6 months of essential expenses (rent, food, utilities, minimum debt payments). If your income changes from month to month, aim higher, such as 6–12 months. Start with a smaller first target, such as $500–$1,000, to handle small surprises, then build from there."
      },
      {
        heading: "Where to keep it",
        text: "Keep your emergency fund where you can get to it, apart from your spending money (so you're not tempted) and out of stocks. Once you have it, resist the urge to invest it. Its job is to cover the unexpected, not to grow."
      }
    ],
    takeaways: [
      "Build your emergency fund first, before investing or other big goals",
      "Target 3–6 months of essential expenses (not total income)",
      "Start with a $500–$1,000 mini-fund and build from there",
      "Keep it where you can get to it, apart from your spending money"
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
        text: "Sending money abroad through traditional services often costs several percent of the amount in fees, so part of it never reaches family. Costs vary a lot from one country pair to another, so compare before you send."
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
      "Traditional remittance fees can take a noticeable share of what you send",
      "Digital-dollar transfers can cost pennies regardless of amount",
      "The recipient needs a way to convert to local currency, and options are still growing",
      "Crypto remittances are a major use case driving blockchain adoption in Africa"
    ]
  }
];
