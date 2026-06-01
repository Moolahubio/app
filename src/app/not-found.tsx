import Link from "next/link";
import { MoolaMark } from "@/components/brand/Logo";
import { Button } from "@/components/ui";

export default function NotFound() {
  return (
    <main className="relative isolate flex min-h-screen flex-col items-center justify-center overflow-hidden bg-ink-950 px-6 text-center text-white">
      <div className="absolute inset-0 -z-10 bg-grid-dark [background-size:48px_48px] [mask-image:radial-gradient(60%_50%_at_50%_40%,black,transparent)]" />
      <div className="absolute left-1/2 top-1/3 -z-10 h-72 w-72 -translate-x-1/2 rounded-full bg-jade-500/20 blur-[120px]" />
      <MoolaMark tone="light" className="h-16 w-16" />
      <p className="mt-8 font-mono text-xs uppercase tracking-[0.2em] text-jade-300">Error 404</p>
      <h1 className="mt-3 font-display text-4xl font-bold tracking-tight">
        This page wandered off
      </h1>
      <p className="mt-3 max-w-sm text-white/60">
        The page you&apos;re looking for doesn&apos;t exist — but your savings are right where you
        left them.
      </p>
      <div className="mt-8 flex gap-3">
        <Button href="/">Go to dashboard</Button>
        <Button href="/" variant="secondary">
          Back home
        </Button>
      </div>
    </main>
  );
}
