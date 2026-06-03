import {
  ShieldCheck,
  Wallet as WalletIcon,
  Bell,
  Globe,
  LogOut,
  BadgeCheck,
  TrendingUp,
  AlertCircle,
  ChevronRight
} from "lucide-react";
import { Link } from "wouter";
import { Card, Badge, Avatar, Button, Eyebrow } from "@/components/ui";
import { PageHeader } from "@/components/app/bits";
import { CopyButton } from "@/components/app/forms";
import { useGetMe, useGetDashboardSummary, useLogout, getGetMeQueryKey } from "@workspace/api-client-react";
import { formatMoney, truncateAddress } from "@/lib/utils";
import { useQueryClient } from "@tanstack/react-query";

const settings = [
  { icon: Bell, label: "Notifications", detail: "Reminders and activity", href: "/notifications" },
  { icon: TrendingUp, label: "Activity & yield", detail: "Ledger and earnings", href: "/activity" },
  { icon: Globe, label: "Learn", detail: "Financial empowerment", href: "/learn" },
  { icon: ShieldCheck, label: "Wallet security", detail: "Deposits on Base", href: "/wallet" },
] as const;

export default function ProfilePage() {
  const { data: user, isLoading: isUserLoading } = useGetMe();
  const { data: summary, isLoading: isSummaryLoading } = useGetDashboardSummary();
  const logoutMutation = useLogout();
  const queryClient = useQueryClient();

  if (isUserLoading || isSummaryLoading) return <div className="p-8 text-center text-ink-400">Loading profile...</div>;
  if (!user || !summary) return null;

  const verified = user.kycStatus === "verified";
  const address = user.walletAddress ?? "Not provisioned";

  return (
    <div className="mx-auto max-w-4xl space-y-6">
      <PageHeader eyebrow="Profile" title="Account & settings" />

      {/* identity card */}
      <Card className="relative overflow-hidden border-ink-900 bg-ink-950 p-6 text-white lg:p-8">
        <div
          className="pointer-events-none absolute inset-0 bg-grid-dark [background-size:32px_32px] opacity-35"
          aria-hidden
        />
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div className="relative z-10 flex items-center gap-4">
            <Avatar name={user.name} tone="jade" className="h-16 w-16 text-lg" />
            <div>
              <h2 className="font-display text-xl font-bold">{user.name}</h2>
              <p className="text-sm text-white/55">{user.email}</p>
            </div>
          </div>
          <div className="relative z-10">
            {verified ? (
              <Badge tone="jade" className="bg-jade-500/15 text-jade-300 ring-jade-400/20">
                <BadgeCheck className="h-3.5 w-3.5" /> KYC Verified
              </Badge>
            ) : (
              <Badge tone="amber">
                <AlertCircle className="h-3.5 w-3.5" /> KYC required
              </Badge>
            )}
          </div>
        </div>

        <div className="relative z-10 mt-6 rounded-2xl border border-white/10 bg-white/[0.03] p-4">
          <div className="flex items-center gap-2">
            <WalletIcon className="h-4 w-4 text-jade-400" />
            <p className="font-mono text-[10px] uppercase tracking-[0.18em] text-white/45">
              Base wallet · non-custodial
            </p>
          </div>
          <div className="mt-2 flex items-center justify-between gap-3">
            <code className="truncate font-mono text-sm text-white/80">
              {truncateAddress(address, 8, 8)}
            </code>
            {user.walletAddress && <CopyButton value={address} />}
          </div>
        </div>
      </Card>

      {!verified && (
        <Card className="flex flex-wrap items-center justify-between gap-4 border-ink-900/[0.06] bg-white p-5">
          <p className="text-sm text-ink-600 flex-1">
            <span className="font-semibold text-ink-900">No verification needed</span> to deposit or
            withdraw USDC. Identity verification will be added for local-currency support (coming
            soon) — you can complete it early if you like.
          </p>
          <Button size="sm" variant="secondary">
            Verify identity
          </Button>
        </Card>
      )}

      {/* balance snapshot */}
      <div className="grid gap-4 sm:grid-cols-3">
        <Card className="p-5">
          <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-ink-400">Balance</p>
          <p className="mt-1 font-display text-2xl font-bold text-ink-900">
            {formatMoney(summary.totalCents)}
          </p>
        </Card>
        <Card className="p-5">
          <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-ink-400">
            Yield earned
          </p>
          <p className="mt-1 font-display text-2xl font-bold text-jade-600">
            {formatMoney(Math.floor(summary.totalCents * 0.041))}
          </p>
        </Card>
        <Card className="p-5">
          <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-ink-400">
            Yield APY
          </p>
          <p className="mt-1 font-display text-2xl font-bold text-ink-900">
            {(summary.yieldApy * 100).toFixed(1)}%
          </p>
        </Card>
      </div>

      {/* settings list */}
      <Card className="overflow-hidden p-1">
        <div className="divide-y divide-ink-900/[0.06]">
          {settings.map((item) => {
            const Icon = item.icon;
            return (
              <Link
                key={item.href}
                href={item.href}
                className="flex items-center justify-between px-4 py-3.5 transition-colors hover:bg-mist"
              >
                <div className="flex items-center gap-3">
                  <span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-ink-900/[0.06] text-ink-700">
                    <Icon className="h-5 w-5" />
                  </span>
                  <div>
                    <p className="text-sm font-semibold text-ink-900">{item.label}</p>
                    <p className="text-xs text-ink-500">{item.detail}</p>
                  </div>
                </div>
                <ChevronRight className="h-5 w-5 text-ink-300" />
              </Link>
            );
          })}
        </div>
      </Card>

      <button
        onClick={() => {
          logoutMutation.mutate(undefined, {
            onSuccess: () => queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() })
          });
        }}
        disabled={logoutMutation.isPending}
        className="flex w-full items-center justify-center gap-2 rounded-2xl border border-ink-900/[0.08] bg-white py-3.5 text-sm font-semibold text-ink-600 transition-[color,background-color] duration-150 hover:bg-mist hover:text-ink-900 focus-ring"
      >
        <LogOut className="h-4 w-4" /> {logoutMutation.isPending ? "Signing out..." : "Sign out"}
      </button>

      <div className="flex flex-wrap items-center justify-center gap-2 pt-2 text-center text-sm text-ink-400">
        <Eyebrow className="text-ink-300">Save Now · Grow Together</Eyebrow>
        <span className="text-ink-200">·</span>
        <a
          href="https://moolahub.io/"
          target="_blank"
          rel="noopener noreferrer"
          className="text-jade-600 hover:text-jade-700"
        >
          moolahub.io
        </a>
      </div>
    </div>
  );
}
