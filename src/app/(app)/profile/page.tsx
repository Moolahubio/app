import {
  ShieldCheck,
  Copy,
  Wallet,
  Bell,
  Globe,
  LogOut,
  ChevronRight,
  BadgeCheck,
  TrendingUp,
} from "lucide-react";
import { Card, Badge, Avatar, Eyebrow } from "@/components/ui";
import { PageHeader } from "@/components/app/bits";
import { currentUser, wallet } from "@/lib/data";
import { formatMoney, truncateAddress } from "@/lib/utils";

const settings = [
  { icon: Bell, label: "Notifications & reminders", detail: "Push, SMS, email" },
  { icon: TrendingUp, label: "Yield preferences", detail: "Opted in · Blend" },
  { icon: Globe, label: "Currency & region", detail: "GHS · Ghana" },
  { icon: ShieldCheck, label: "Security & recovery", detail: "Passkey enabled" },
];

export default function ProfilePage() {
  return (
    <div className="mx-auto max-w-4xl space-y-6">
      <PageHeader eyebrow="Profile" title="Account & settings" />

      {/* identity card */}
      <Card className="relative isolate overflow-hidden border-0 bg-ink-950 p-6 text-white lg:p-8">
        <div className="absolute inset-0 -z-10 bg-grid-dark [background-size:32px_32px] [mask-image:radial-gradient(70%_80%_at_90%_0%,black,transparent)]" />
        <div className="absolute -right-10 -top-16 -z-10 h-56 w-56 rounded-full bg-jade-500/20 blur-[90px]" />
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div className="flex items-center gap-4">
            <Avatar name={currentUser.name} tone="jade" className="h-16 w-16 text-lg" />
            <div>
              <h2 className="font-display text-xl font-bold">{currentUser.name}</h2>
              <p className="text-sm text-white/55">{currentUser.email}</p>
            </div>
          </div>
          <Badge tone="jade" className="bg-jade-500/15 text-jade-300 ring-jade-400/20">
            <BadgeCheck className="h-3.5 w-3.5" /> KYC Verified
          </Badge>
        </div>

        <div className="mt-6 rounded-2xl border border-white/10 bg-white/[0.03] p-4">
          <div className="flex items-center gap-2">
            <Wallet className="h-4 w-4 text-jade-400" />
            <p className="font-mono text-[10px] uppercase tracking-[0.18em] text-white/45">
              Stellar wallet · non-custodial
            </p>
          </div>
          <div className="mt-2 flex items-center justify-between gap-3">
            <code className="truncate font-mono text-sm text-white/80">
              {truncateAddress(currentUser.walletAddress, 8, 8)}
            </code>
            <button className="inline-flex items-center gap-1.5 rounded-full bg-white/10 px-3 py-1.5 text-xs font-medium text-white transition-colors hover:bg-white/15 focus-ring">
              <Copy className="h-3.5 w-3.5" /> Copy
            </button>
          </div>
        </div>
      </Card>

      {/* balance snapshot */}
      <div className="grid gap-4 sm:grid-cols-3">
        <Card className="p-5">
          <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-ink-400">Balance</p>
          <p className="mt-1 font-display text-2xl font-bold text-ink-900">
            {formatMoney(wallet.balanceCents)}
          </p>
        </Card>
        <Card className="p-5">
          <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-ink-400">
            Yield earned
          </p>
          <p className="mt-1 font-display text-2xl font-bold text-jade-600">
            {formatMoney(wallet.yieldEarnedCents)}
          </p>
        </Card>
        <Card className="p-5">
          <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-ink-400">
            Member since
          </p>
          <p className="mt-1 font-display text-2xl font-bold text-ink-900">
            {new Date(currentUser.memberSince).toLocaleDateString("en-US", {
              month: "short",
              year: "numeric",
            })}
          </p>
        </Card>
      </div>

      {/* settings list */}
      <Card className="divide-y divide-ink-900/[0.06] p-2">
        {settings.map((s) => (
          <button
            key={s.label}
            className="flex w-full items-center gap-4 rounded-2xl px-4 py-4 text-left transition-colors hover:bg-mist focus-ring"
          >
            <span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-jade-50 text-jade-600">
              <s.icon className="h-5 w-5" />
            </span>
            <div className="flex-1">
              <p className="text-sm font-semibold text-ink-900">{s.label}</p>
              <p className="text-xs text-ink-500">{s.detail}</p>
            </div>
            <ChevronRight className="h-5 w-5 text-ink-300" />
          </button>
        ))}
      </Card>

      <button className="flex w-full items-center justify-center gap-2 rounded-2xl border border-ink-900/[0.08] bg-white py-3.5 text-sm font-semibold text-ink-600 transition-colors hover:text-ink-900 focus-ring">
        <LogOut className="h-4 w-4" /> Sign out
      </button>

      <Eyebrow className="pt-2 text-center text-ink-300">Save Now · Grow Together</Eyebrow>
    </div>
  );
}
