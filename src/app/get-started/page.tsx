import Link from "next/link";
import { Mail, ArrowRight, ShieldCheck, Lock, Users, Sparkles } from "lucide-react";
import { Logo, MoolaMark } from "@/components/brand/Logo";
import { Button } from "@/components/ui";
import { AscendingChart } from "@/components/marketing/AscendingChart";

export const metadata = { title: "Get started" };

export default function GetStartedPage() {
  return (
    <main className="grid min-h-screen lg:grid-cols-2">
      {/* ---------------------------------------------------- brand panel */}
      <section className="relative isolate hidden flex-col justify-between overflow-hidden bg-ink-950 p-12 text-white lg:flex">
        <div className="absolute inset-0 -z-10 bg-grid-dark [background-size:48px_48px] [mask-image:radial-gradient(80%_60%_at_30%_20%,black,transparent)]" />
        <div className="absolute -left-10 top-20 -z-10 h-80 w-80 rounded-full bg-jade-500/20 blur-[120px]" />

        <Link href="/">
          <Logo tone="light" />
        </Link>

        <div>
          <p className="font-mono text-xs uppercase tracking-[0.2em] text-jade-300">
            Built on Stellar
          </p>
          <h1 className="mt-4 font-display text-5xl font-extrabold leading-[1.05] tracking-tight">
            Save Now.
            <br />
            <span className="text-jade-400">Grow Together.</span>
          </h1>
          <p className="mt-5 max-w-sm text-lg text-white/60">
            Open a non-custodial wallet in minutes. No bank account needed — just
            you, your goals, and your circle.
          </p>
          <div className="mt-8 max-w-md rounded-3xl border border-white/10 bg-white/[0.03] p-5">
            <AscendingChart className="max-h-32" />
          </div>
        </div>

        <div className="flex flex-wrap gap-x-6 gap-y-2 text-sm text-white/50">
          <span className="inline-flex items-center gap-2">
            <Lock className="h-4 w-4 text-jade-400" /> Non-custodial
          </span>
          <span className="inline-flex items-center gap-2">
            <ShieldCheck className="h-4 w-4 text-jade-400" /> On-chain verified
          </span>
          <span className="inline-flex items-center gap-2">
            <Users className="h-4 w-4 text-jade-400" /> Trusted circles
          </span>
        </div>
      </section>

      {/* ----------------------------------------------------- form panel */}
      <section className="flex flex-col justify-center bg-mist px-6 py-12 sm:px-12">
        <div className="mx-auto w-full max-w-sm">
          <div className="lg:hidden">
            <Logo />
          </div>

          <div className="mt-8 lg:mt-0">
            <span className="inline-flex items-center gap-1.5 rounded-full bg-jade-50 px-3 py-1 text-xs font-medium text-jade-700 ring-1 ring-inset ring-jade-500/20">
              <Sparkles className="h-3.5 w-3.5" /> Free to join
            </span>
            <h2 className="mt-4 font-display text-3xl font-bold tracking-tight text-ink-900">
              Create your account
            </h2>
            <p className="mt-2 text-ink-500">
              Start saving toward what matters — on your own and with your community.
            </p>
          </div>

          <div className="mt-8 space-y-3">
            <label className="block">
              <span className="text-sm font-medium text-ink-700">Email or phone</span>
              <div className="mt-1.5 flex items-center gap-2 rounded-2xl border border-ink-900/10 bg-white px-4 focus-within:ring-2 focus-within:ring-jade-500/40">
                <Mail className="h-5 w-5 text-ink-400" />
                <input
                  type="email"
                  placeholder="you@example.com"
                  className="h-12 w-full bg-transparent text-ink-900 outline-none placeholder:text-ink-400"
                />
              </div>
            </label>

            <Button href="/app" size="lg" className="w-full">
              Continue <ArrowRight className="h-4 w-4" />
            </Button>
          </div>

          <div className="my-6 flex items-center gap-4">
            <span className="h-px flex-1 bg-ink-900/10" />
            <span className="font-mono text-[10px] uppercase tracking-[0.18em] text-ink-400">
              or continue with
            </span>
            <span className="h-px flex-1 bg-ink-900/10" />
          </div>

          <div className="grid grid-cols-2 gap-3">
            {["Google", "Apple"].map((provider) => (
              <Link
                key={provider}
                href="/app"
                className="flex h-12 items-center justify-center gap-2 rounded-2xl border border-ink-900/10 bg-white text-sm font-semibold text-ink-700 transition-colors hover:bg-white hover:shadow-card focus-ring"
              >
                {provider}
              </Link>
            ))}
          </div>

          <p className="mt-8 text-center text-xs leading-relaxed text-ink-400">
            By continuing you agree to MoolaHub&apos;s Terms and acknowledge our
            Privacy Policy. Identity verification (KYC) is required to deposit via
            local currency.
          </p>

          <p className="mt-6 flex items-center justify-center gap-2 text-sm text-ink-500">
            <MoolaMark className="h-5 w-5" />
            Already have an account?{" "}
            <Link href="/app" className="font-semibold text-jade-600 hover:text-jade-700">
              Sign in
            </Link>
          </p>
        </div>
      </section>
    </main>
  );
}
