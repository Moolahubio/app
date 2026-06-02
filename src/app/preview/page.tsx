import Link from "next/link";
import {
  ArrowRight,
  ShieldCheck,
  Users,
  Target,
  GraduationCap,
  Bell,
  CalendarClock,
  ScrollText,
  Link2,
  Lock,
  Sparkles,
  CheckCircle2,
} from "lucide-react";
import { SiteNav } from "@/components/marketing/SiteNav";
import { SiteFooter } from "@/components/marketing/SiteFooter";
import { AscendingChart } from "@/components/marketing/AscendingChart";
import { MoolaMark } from "@/components/brand/Logo";
import { Button, Eyebrow, Badge } from "@/components/ui";
import { lessons } from "@/lib/content/lessons";

export default function HomePage() {
  return (
    <main className="overflow-x-hidden bg-mist">
      {/* ============================================================ HERO */}
      <section className="relative isolate overflow-hidden bg-ink-950 text-white">
        <SiteNav />

        {/* background texture */}
        <div className="absolute inset-0 -z-10 bg-grid-dark [background-size:48px_48px] [mask-image:radial-gradient(80%_60%_at_50%_0%,black,transparent)]" />
        <div className="absolute inset-0 -z-10 bg-radial-jade" />
        <div className="absolute right-0 top-0 -z-10 h-[480px] w-[480px] rounded-full bg-jade-500/20 blur-[120px]" />

        <div className="mx-auto grid max-w-7xl items-center gap-12 px-6 pb-24 pt-36 lg:grid-cols-2 lg:gap-8 lg:px-8 lg:pb-28 lg:pt-44">
          <div className="animate-fade-up">
            <div className="inline-flex items-center gap-2 rounded-full border border-white/15 bg-white/5 px-3 py-1.5 backdrop-blur">
              <span className="relative flex h-2 w-2">
                <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-jade-400 opacity-75" />
                <span className="relative inline-flex h-2 w-2 rounded-full bg-jade-400" />
              </span>
              <span className="font-mono text-xs uppercase tracking-[0.18em] text-white/70">
                Built on Stellar
              </span>
            </div>

            <h1 className="mt-6 font-display text-5xl font-extrabold leading-[1.05] tracking-tight text-balance sm:text-6xl lg:text-7xl">
              Save Now.
              <br />
              <span className="text-jade-400">Grow Together.</span>
            </h1>

            <p className="mt-6 max-w-md text-lg leading-relaxed text-white/65">
              MoolaHub is a non-custodial savings app that brings the trusted
              Susu tradition on-chain. Hit your goals, save with your circle, and
              watch every contribution verified on the Stellar ledger.
            </p>

            <div className="mt-8 flex flex-wrap items-center gap-3">
              <Button href="/login" size="lg">
                Start saving
                <ArrowRight className="h-4 w-4" />
              </Button>
              <Button href="/" size="lg" variant="secondary">
                Explore the app
              </Button>
            </div>

            <div className="mt-10 flex items-center gap-6 text-sm text-white/50">
              <span className="inline-flex items-center gap-2">
                <Lock className="h-4 w-4 text-jade-400" /> Non-custodial
              </span>
              <span className="inline-flex items-center gap-2">
                <ShieldCheck className="h-4 w-4 text-jade-400" /> On-chain verified
              </span>
            </div>
          </div>

          {/* hero visual */}
          <div className="relative animate-fade-up [animation-delay:120ms]">
            <div className="rounded-4xl border border-white/10 bg-white/[0.03] p-6 backdrop-blur-sm shadow-glow sm:p-8">
              <div className="flex items-center justify-between">
                <div>
                  <p className="font-mono text-xs uppercase tracking-[0.18em] text-white/45">
                    Total saved
                  </p>
                  <p className="mt-1 font-display text-3xl font-bold">
                    4,826.50 <span className="text-jade-400">USDC</span>
                  </p>
                </div>
                <MoolaMark tone="light" className="h-11 w-11" />
              </div>
              <AscendingChart className="mt-4" />
              <div className="mt-2 flex items-center justify-between font-mono text-xs uppercase tracking-[0.18em] text-white/45">
                <span>GHS · NGN · USDC</span>
                <span className="inline-flex items-center gap-1.5 text-jade-400">
                  <Sparkles className="h-3.5 w-3.5" /> +4.1% APY
                </span>
              </div>
            </div>
          </div>
        </div>

        {/* powered-by strip */}
        <div className="border-t border-white/10">
          <div className="mx-auto flex max-w-7xl flex-wrap items-center justify-center gap-x-10 gap-y-3 px-6 py-6 lg:px-8">
            <span className="font-mono text-xs uppercase tracking-[0.2em] text-white/35">
              Powered by
            </span>
            {["Stellar", "USDC", "Privy", "Blend", "Soroban"].map((name) => (
              <span key={name} className="text-sm font-semibold text-white/55">
                {name}
              </span>
            ))}
          </div>
        </div>
      </section>

      {/* ======================================================== FEATURES */}
      <section className="mx-auto max-w-7xl px-6 py-24 lg:px-8">
        <div className="max-w-2xl">
          <Eyebrow>Everything in one hub</Eyebrow>
          <h2 className="mt-3 font-display text-4xl font-bold tracking-tight text-ink-900 sm:text-5xl text-balance">
            Built for how communities really save
          </h2>
          <p className="mt-4 text-lg text-ink-500">
            Four pillars, one wallet. Save on your own, save with your people,
            learn as you go — and verify all of it on-chain.
          </p>
        </div>

        <div className="mt-14 grid gap-6 sm:grid-cols-2 lg:grid-cols-4">
          {[
            {
              icon: Users,
              title: "Susu Circles",
              text: "Join or start a rotating savings circle. An audited smart contract holds the rules — not a person.",
            },
            {
              icon: Target,
              title: "Savings Goals",
              text: "Set a target, automate weekly contributions, and watch progress climb toward the goal star.",
            },
            {
              icon: GraduationCap,
              title: "Learn",
              text: "Bite-sized financial-empowerment lessons that turn good habits into second nature.",
            },
            {
              icon: ShieldCheck,
              title: "Verified on-chain",
              text: "Every deposit, contribution and payout settles on Stellar — public, permanent, provable.",
            },
          ].map((f) => (
            <div
              key={f.title}
              className="group rounded-3xl border border-ink-900/[0.07] bg-white p-6 shadow-card transition-all hover:-translate-y-1 hover:shadow-card-hover"
            >
              <span className="inline-flex h-12 w-12 items-center justify-center rounded-2xl bg-jade-50 text-jade-600 transition-colors group-hover:bg-jade-500 group-hover:text-white">
                <f.icon className="h-6 w-6" />
              </span>
              <h3 className="mt-5 font-display text-lg font-bold text-ink-900">{f.title}</h3>
              <p className="mt-2 text-sm leading-relaxed text-ink-500">{f.text}</p>
            </div>
          ))}
        </div>
      </section>

      {/* ========================================================= CIRCLES */}
      <section id="circles" className="border-y border-ink-900/[0.06] bg-white">
        <div className="mx-auto grid max-w-7xl items-center gap-14 px-6 py-24 lg:grid-cols-2 lg:px-8">
          <div>
            <Eyebrow>Susu Circles</Eyebrow>
            <h2 className="mt-3 font-display text-4xl font-bold tracking-tight text-ink-900 sm:text-5xl text-balance">
              A centuries-old tradition, now tamper-proof
            </h2>
            <p className="mt-4 text-lg text-ink-500">
              Everyone contributes a fixed amount each round. Each round, one
              member receives the whole pot. MoolaHub replaces the human
              collector with an audited Soroban contract — so the rules can&apos;t
              be bent and the schedule is guaranteed.
            </p>

            <ul className="mt-8 space-y-4">
              {[
                "Transparent payout order — agreed up front, locked on-chain",
                "Automatic contribution reminders so no one falls behind",
                "Full contribution history, provable on the Stellar ledger",
              ].map((item) => (
                <li key={item} className="flex items-start gap-3">
                  <CheckCircle2 className="mt-0.5 h-5 w-5 shrink-0 text-jade-500" />
                  <span className="text-ink-700">{item}</span>
                </li>
              ))}
            </ul>

            <div className="mt-8">
              <Button href="/circles" variant="dark">
                See how circles work
                <ArrowRight className="h-4 w-4" />
              </Button>
            </div>
          </div>

          {/* circle visual */}
          <div className="relative rounded-4xl border border-ink-900/[0.07] bg-mist p-8 shadow-card">
            <div className="flex items-center justify-between">
              <div>
                <p className="font-semibold text-ink-900">Makola Market Circle</p>
                <p className="text-sm text-ink-500">Weekly · 8 members</p>
              </div>
              <Badge tone="jade">
                <span className="h-1.5 w-1.5 rounded-full bg-jade-500" /> Round 3 of 8
              </Badge>
            </div>

            <div className="mt-6 grid grid-cols-4 gap-3">
              {[
                "paid", "paid", "current", "upcoming",
                "upcoming", "upcoming", "upcoming", "upcoming",
              ].map((state, i) => (
                <div
                  key={i}
                  className={`flex aspect-square flex-col items-center justify-center rounded-2xl border text-center ${
                    state === "current"
                      ? "border-jade-500 bg-jade-50"
                      : state === "paid"
                        ? "border-transparent bg-jade-500/90 text-white"
                        : "border-ink-900/[0.06] bg-white text-ink-400"
                  }`}
                >
                  <span className="text-lg font-bold">{i + 1}</span>
                  <span className="font-mono text-[9px] uppercase tracking-wide">
                    {state === "current" ? "You" : state === "paid" ? "Paid" : "—"}
                  </span>
                </div>
              ))}
            </div>

            <div className="mt-6 flex items-center justify-between rounded-2xl bg-ink-900 px-5 py-4 text-white">
              <div>
                <p className="font-mono text-[10px] uppercase tracking-[0.18em] text-white/50">
                  This round&apos;s pot
                </p>
                <p className="font-display text-2xl font-bold">400.00 USDC</p>
              </div>
              <div className="text-right">
                <p className="font-mono text-[10px] uppercase tracking-[0.18em] text-white/50">
                  Your turn
                </p>
                <p className="font-semibold text-jade-400">Jun 5</p>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* =========================================================== GOALS */}
      <section id="goals" className="mx-auto max-w-7xl px-6 py-24 lg:px-8">
        <div className="grid items-center gap-14 lg:grid-cols-2">
          <div className="order-2 grid gap-4 lg:order-1">
            {[
              { emoji: "🏠", name: "Rent buffer", saved: 1640, target: 2000, pct: 82 },
              { emoji: "💻", name: "New laptop", saved: 860, target: 1200, pct: 72 },
              { emoji: "🛟", name: "Emergency fund", saved: 620, target: 1500, pct: 41 },
            ].map((g) => (
              <div
                key={g.name}
                className="flex items-center gap-4 rounded-3xl border border-ink-900/[0.07] bg-white p-5 shadow-card"
              >
                <span className="flex h-12 w-12 items-center justify-center rounded-2xl bg-mist text-2xl">
                  {g.emoji}
                </span>
                <div className="flex-1">
                  <div className="flex items-center justify-between">
                    <p className="font-semibold text-ink-900">{g.name}</p>
                    <p className="text-sm text-ink-500">
                      <span className="font-semibold text-ink-900">{g.saved}</span> / {g.target}
                    </p>
                  </div>
                  <div className="mt-2 h-2 w-full overflow-hidden rounded-full bg-ink-900/[0.07]">
                    <div className="h-full rounded-full bg-jade-500" style={{ width: `${g.pct}%` }} />
                  </div>
                </div>
              </div>
            ))}
          </div>

          <div className="order-1 lg:order-2">
            <Eyebrow>Savings Goals</Eyebrow>
            <h2 className="mt-3 font-display text-4xl font-bold tracking-tight text-ink-900 sm:text-5xl text-balance">
              Name it, automate it, reach it
            </h2>
            <p className="mt-4 text-lg text-ink-500">
              Goals are simple allocations over your one non-custodial wallet —
              no scattered accounts. Set a target and a weekly auto-save, and
              MoolaHub keeps you climbing. Opt in to yield and idle savings can
              earn while you wait.
            </p>
            <div className="mt-8">
              <Button href="/goals" variant="dark">
                Create a goal
                <ArrowRight className="h-4 w-4" />
              </Button>
            </div>
          </div>
        </div>
      </section>

      {/* ======================================================= EDUCATION */}
      <section id="learn" className="border-y border-ink-900/[0.06] bg-white">
        <div className="mx-auto max-w-7xl px-6 py-24 lg:px-8">
          <div className="flex flex-col items-start justify-between gap-6 sm:flex-row sm:items-end">
            <div className="max-w-2xl">
              <Eyebrow>Learn</Eyebrow>
              <h2 className="mt-3 font-display text-4xl font-bold tracking-tight text-ink-900 sm:text-5xl text-balance">
                Financial empowerment, built in
              </h2>
              <p className="mt-4 text-lg text-ink-500">
                Short, practical lessons that meet you where you are — from your
                first emergency fund to understanding on-chain yield.
              </p>
            </div>
            <Button href="/learn" variant="secondary">
              Browse all lessons
            </Button>
          </div>

          <div className="mt-12 grid gap-6 sm:grid-cols-2 lg:grid-cols-4">
            {lessons.map((lesson) => (
              <Link
                key={lesson.slug}
                href={`/learn/${lesson.slug}`}
                className="group flex flex-col rounded-3xl border border-ink-900/[0.07] bg-mist p-6 transition-all hover:-translate-y-1 hover:bg-white hover:shadow-card-hover"
              >
                <div className="flex items-center justify-between">
                  <span className="text-3xl">{lesson.emoji}</span>
                  <Badge tone={lesson.level === "Beginner" ? "jade" : "sky"}>{lesson.level}</Badge>
                </div>
                <h3 className="mt-5 font-display text-lg font-bold leading-snug text-ink-900">
                  {lesson.title}
                </h3>
                <p className="mt-2 flex-1 text-sm leading-relaxed text-ink-500">{lesson.summary}</p>
                <p className="mt-4 font-mono text-xs uppercase tracking-[0.15em] text-ink-400">
                  {lesson.category} · {lesson.minutes} min
                </p>
              </Link>
            ))}
          </div>
        </div>
      </section>

      {/* ==================================================== VERIFICATION */}
      <section id="verification" className="relative isolate overflow-hidden bg-ink-950 text-white">
        <div className="absolute inset-0 -z-10 bg-grid-dark [background-size:48px_48px] [mask-image:radial-gradient(70%_70%_at_50%_50%,black,transparent)]" />
        <div className="absolute left-1/2 top-0 -z-10 h-[400px] w-[700px] -translate-x-1/2 rounded-full bg-jade-500/15 blur-[120px]" />

        <div className="mx-auto max-w-7xl px-6 py-24 lg:px-8">
          <div className="mx-auto max-w-2xl text-center">
            <Eyebrow tone="light">Blockchain verification</Eyebrow>
            <h2 className="mt-3 font-display text-4xl font-bold tracking-tight sm:text-5xl text-balance">
              Don&apos;t trust us. Verify it.
            </h2>
            <p className="mt-4 text-lg text-white/60">
              MoolaHub never holds your keys, and the chain — not our database —
              is the source of truth. Every movement is independently verifiable.
            </p>
          </div>

          <div className="mt-14 grid gap-6 md:grid-cols-3">
            {[
              {
                icon: Lock,
                title: "Non-custodial by design",
                text: "Your wallet, your keys. MoolaHub can never move your funds without your signature — full stop.",
              },
              {
                icon: ShieldCheck,
                title: "Audited contracts",
                text: "Susu pooling runs on Soroban smart contracts. Pooled-funds contracts ship to mainnet only after an independent security audit.",
              },
              {
                icon: Link2,
                title: "Provable on Stellar",
                text: "Every deposit, contribution and payout has a transaction hash you can open in any block explorer.",
              },
            ].map((c) => (
              <div
                key={c.title}
                className="rounded-3xl border border-white/10 bg-white/[0.03] p-7 backdrop-blur-sm"
              >
                <span className="inline-flex h-12 w-12 items-center justify-center rounded-2xl bg-jade-500/15 text-jade-400">
                  <c.icon className="h-6 w-6" />
                </span>
                <h3 className="mt-5 font-display text-lg font-bold">{c.title}</h3>
                <p className="mt-2 text-sm leading-relaxed text-white/55">{c.text}</p>
              </div>
            ))}
          </div>

          {/* sample on-chain receipt */}
          <div className="mx-auto mt-10 max-w-2xl rounded-2xl border border-white/10 bg-ink-900/80 p-5 font-mono text-sm">
            <div className="flex items-center justify-between text-white/40">
              <span className="text-xs uppercase tracking-[0.18em]">Ledger receipt</span>
              <span className="inline-flex items-center gap-1.5 text-jade-400">
                <CheckCircle2 className="h-4 w-4" /> Confirmed
              </span>
            </div>
            <div className="mt-3 space-y-1.5 text-white/70">
              <p><span className="text-white/40">op&nbsp;&nbsp;&nbsp;&nbsp;</span> contribution · Makola Market Circle</p>
              <p><span className="text-white/40">amount</span> 50.00 USDC</p>
              <p className="truncate"><span className="text-white/40">tx&nbsp;&nbsp;&nbsp;&nbsp;</span> 9e44f1c3…a7b22d09f3a91c</p>
            </div>
          </div>
        </div>
      </section>

      {/* ===================================================== TRUST/REMIND */}
      <section className="mx-auto max-w-7xl px-6 py-24 lg:px-8">
        <div className="max-w-2xl">
          <Eyebrow>Trust features</Eyebrow>
          <h2 className="mt-3 font-display text-4xl font-bold tracking-tight text-ink-900 sm:text-5xl text-balance">
            Built so no one gets left behind
          </h2>
          <p className="mt-4 text-lg text-ink-500">
            Saving together only works when everyone&apos;s informed. MoolaHub
            keeps the whole circle on the same page.
          </p>
        </div>

        <div className="mt-12 grid gap-6 md:grid-cols-3">
          {[
            {
              icon: Bell,
              title: "Payment reminders",
              text: "Friendly nudges before every contribution is due — by push, SMS, or email — so no round is ever missed.",
            },
            {
              icon: CalendarClock,
              title: "Payout schedules",
              text: "Everyone sees the full rotation up front: who gets the pot, and exactly when. No surprises.",
            },
            {
              icon: ScrollText,
              title: "Contribution history",
              text: "A complete, exportable record of every payment — each one linked to its on-chain proof.",
            },
          ].map((c) => (
            <div key={c.title} className="rounded-3xl border border-ink-900/[0.07] bg-white p-7 shadow-card">
              <span className="inline-flex h-12 w-12 items-center justify-center rounded-2xl bg-jade-50 text-jade-600">
                <c.icon className="h-6 w-6" />
              </span>
              <h3 className="mt-5 font-display text-lg font-bold text-ink-900">{c.title}</h3>
              <p className="mt-2 text-sm leading-relaxed text-ink-500">{c.text}</p>
            </div>
          ))}
        </div>
      </section>

      {/* ============================================================= CTA */}
      <section className="mx-auto max-w-7xl px-6 pb-24 lg:px-8">
        <div className="relative isolate overflow-hidden rounded-4xl bg-ink-950 px-8 py-16 text-center text-white sm:px-16 sm:py-20">
          <div className="absolute inset-0 -z-10 bg-radial-jade" />
          <div className="absolute -right-10 -top-10 -z-10 h-72 w-72 rounded-full bg-jade-500/25 blur-[100px]" />
          <MoolaMark tone="light" className="mx-auto h-14 w-14" />
          <h2 className="mt-6 font-display text-4xl font-bold tracking-tight sm:text-5xl text-balance">
            Save Now. Grow Together.
          </h2>
          <p className="mx-auto mt-4 max-w-xl text-lg text-white/60">
            Join MoolaHub today. Open a wallet in minutes — no bank account
            needed — and start building toward what matters with your community.
          </p>
          <div className="mt-8 flex flex-wrap justify-center gap-3">
            <Button href="/login" size="lg">
              Create your account
              <ArrowRight className="h-4 w-4" />
            </Button>
            <Button href="/" size="lg" variant="secondary">
              Explore the demo
            </Button>
          </div>
        </div>
      </section>

      <SiteFooter />
    </main>
  );
}
