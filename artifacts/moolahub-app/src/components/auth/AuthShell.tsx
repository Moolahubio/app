import { Link } from "wouter";
import { ShieldCheck, Lock, Users } from "lucide-react";
import { Logo } from "@/components/brand/Logo";
import { AscendingChart } from "@/components/marketing/AscendingChart";

export function AuthShell({ children }: { children: React.ReactNode }) {
  return (
    <main className="grid min-h-[100dvh] lg:grid-cols-2">
      {/* ---------------------------------------------------- brand panel */}
      <section className="relative isolate hidden flex-col justify-between overflow-hidden bg-ink-950 p-12 text-white lg:flex">
        <div className="absolute inset-0 -z-10 bg-grid-dark [background-size:48px_48px] [mask-image:radial-gradient(80%_60%_at_30%_20%,black,transparent)]" />

        <div>
          <Link href="/login">
            <Logo tone="light" />
          </Link>
        </div>

        <div>
          <p className="font-mono text-xs uppercase tracking-[0.2em] text-jade-300">
            Built on Monad
          </p>
          <h1 className="mt-4 font-display text-5xl font-extrabold leading-[1.05] tracking-tight">
            Save. Earn.
            <br />
            <span className="text-jade-400">Belong.</span>
          </h1>
          <p className="mt-5 max-w-sm text-lg text-white/60">
            Personal savings and susu circles in one place. Earn yield as you go,
            and save alongside people you trust.
          </p>
          <div className="glass-dark mt-8 max-w-md rounded-2xl p-5">
            <AscendingChart className="max-h-32" />
          </div>
        </div>

        <div className="flex flex-wrap gap-x-6 gap-y-2 text-sm text-white/65">
          <span className="inline-flex items-center gap-2">
            <Lock className="h-4 w-4 text-jade-400" /> Withdrawals need a second confirmation
          </span>
          <span className="inline-flex items-center gap-2">
            <ShieldCheck className="h-4 w-4 text-jade-400" /> Every transaction has an on-chain receipt
          </span>
          <span className="inline-flex items-center gap-2">
            <Users className="h-4 w-4 text-jade-400" /> Save in circles with people you trust
          </span>
        </div>
      </section>

      {/* ----------------------------------------------------- form panel */}
      <section className="flex flex-col justify-center bg-background px-6 py-12 sm:px-12">
        <div className="mx-auto w-full max-w-sm">
          <div className="mb-8 lg:hidden">
            <Logo />
          </div>
          {children}
        </div>
      </section>
    </main>
  );
}

export const authInputClass =
  "w-full rounded-xl border border-border bg-background px-3.5 py-2.5 text-sm text-foreground outline-none transition-colors placeholder:text-muted-foreground focus:border-jade-500/60 focus-ring";
