import { useEffect } from "react";
import { Link, useLocation } from "wouter";
import { ShieldCheck, Lock, Users } from "lucide-react";
import { Logo } from "@/components/brand/Logo";
import { AscendingChart } from "@/components/marketing/AscendingChart";
import { AuthPanel } from "@/components/auth/AuthPanel";
import { useAuth } from "@/hooks/use-auth";

export default function Login() {
  const { isAuthenticated, isLoading } = useAuth();
  const [, setLocation] = useLocation();

  useEffect(() => {
    if (!isLoading && isAuthenticated) {
      setLocation("/");
    }
  }, [isLoading, isAuthenticated, setLocation]);

  if (!isLoading && isAuthenticated) {
    return null;
  }

  return (
    <main className="grid min-h-[100dvh] lg:grid-cols-2">
      {/* ---------------------------------------------------- brand panel */}
      <section className="relative isolate hidden flex-col justify-between overflow-hidden bg-ink-950 p-12 text-white lg:flex">
        <div className="absolute inset-0 -z-10 bg-grid-dark [background-size:48px_48px] [mask-image:radial-gradient(80%_60%_at_30%_20%,black,transparent)]" />

        <Link href="/login">
          <Logo tone="light" />
        </Link>

        <div>
          <p className="font-mono text-xs uppercase tracking-[0.2em] text-jade-300">
            Connecting People Through Savings
          </p>
          <p className="mt-2 font-mono text-[10px] uppercase tracking-[0.18em] text-white/40">
            Built on Base
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
          <div className="mt-8 max-w-md rounded-2xl border border-white/10 bg-white/[0.04] p-5">
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
          <div className="mb-8 lg:hidden">
            <Logo />
          </div>
          <AuthPanel />
        </div>
      </section>
    </main>
  );
}
