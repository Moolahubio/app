import { Link } from "wouter";
import { ShieldCheck, Lock, Users } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Logo } from "@/components/brand/Logo";
import { GlowLineChart } from "@/components/ui";

export function AuthShell({ children }: { children: React.ReactNode }) {
  const { t } = useTranslation("auth");
  return (
    <main className="mh-bg-grid grid min-h-[100dvh] lg:grid-cols-2">
      {/* ---------------------------------------------------- brand panel */}
      <section className="relative isolate hidden flex-col justify-between overflow-hidden bg-ink-950 p-12 text-white lg:flex">
        <div className="absolute inset-0 -z-10 bg-grid-dark [background-size:48px_48px] [mask-image:radial-gradient(80%_60%_at_30%_20%,black,transparent)]" />
        <div className="absolute inset-0 -z-10 bg-[radial-gradient(circle_at_18%_12%,rgba(14,158,110,0.35),transparent_34rem),radial-gradient(circle_at_88%_82%,rgba(45,212,166,0.18),transparent_30rem)]" />

        <div>
          <Link href="/login">
            <Logo tone="light" />
          </Link>
        </div>

        <div>
          <p className="mh-kicker text-jade-300">{t("shell.eyebrow")}</p>
          <h1 className="mt-4 font-display text-5xl font-bold leading-[1.05] tracking-tight">
            {t("shell.headingLine1")}
            <br />
            <span className="text-jade-400">{t("shell.headingLine2")}</span>
          </h1>
          <p className="mt-5 max-w-sm text-lg text-white/60">
            {t("shell.description")}
          </p>
          <div className="glass-dark mt-8 max-w-md rounded-2xl p-5">
            <GlowLineChart className="h-32 w-full" />
          </div>
        </div>

        <ul className="flex flex-col gap-3 text-sm text-white/70">
          <li className="inline-flex items-center gap-2.5">
            <span className="grid size-8 shrink-0 place-items-center rounded-xl border border-white/10 bg-white/5 text-jade-400">
              <Lock className="h-4 w-4" />
            </span>
            {t("shell.features.withdrawals")}
          </li>
          <li className="inline-flex items-center gap-2.5">
            <span className="grid size-8 shrink-0 place-items-center rounded-xl border border-white/10 bg-white/5 text-jade-400">
              <ShieldCheck className="h-4 w-4" />
            </span>
            {t("shell.features.receipt")}
          </li>
          <li className="inline-flex items-center gap-2.5">
            <span className="grid size-8 shrink-0 place-items-center rounded-xl border border-white/10 bg-white/5 text-jade-400">
              <Users className="h-4 w-4" />
            </span>
            {t("shell.features.circles")}
          </li>
        </ul>
      </section>

      {/* ----------------------------------------------------- form panel */}
      <section className="flex flex-col justify-center px-5 py-12 sm:px-12">
        <div className="mx-auto w-full max-w-md">
          <div className="mb-8 lg:hidden">
            <Logo />
          </div>
          <div className="glass rounded-[var(--mh-radius-lg)] p-6 sm:p-8">
            {children}
          </div>
        </div>
      </section>
    </main>
  );
}

export const authInputClass =
  "mh-input w-full rounded-xl px-3.5 py-2.5 text-sm outline-none focus-ring";
