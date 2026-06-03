import { useRef, useState } from "react";
import {
  Wallet as WalletIcon,
  Bell,
  Globe,
  LogOut,
  TrendingUp,
  ChevronRight,
  Camera,
  Pencil,
  Check,
  X,
  ShieldCheck,
} from "lucide-react";
import { Link } from "wouter";
import { Card, Avatar, Button, Eyebrow } from "@/components/ui";
import { PageHeader } from "@/components/app/bits";
import { CopyButton } from "@/components/app/forms";
import { PasskeysCard } from "@/components/app/PasskeysCard";
import {
  useGetMe,
  useGetDashboardSummary,
  useLogout,
  useUpdateProfile,
  getGetMeQueryKey,
  getGetProfileQueryKey,
} from "@workspace/api-client-react";
import { useUpload } from "@workspace/object-storage-web";
import { formatMoney, truncateAddress, avatarSrc, apiErrorMessage } from "@/lib/utils";
import { useQueryClient } from "@tanstack/react-query";

const settings = [
  { icon: WalletIcon, label: "View wallet", detail: "Balance & address on Base", href: "/wallet" },
  { icon: Bell, label: "Notifications", detail: "Reminders and activity", href: "/notifications" },
  { icon: TrendingUp, label: "Activity & yield", detail: "Ledger and earnings", href: "/activity" },
  { icon: Globe, label: "Learn", detail: "Financial empowerment", href: "/learn" },
  { icon: ShieldCheck, label: "Wallet security", detail: "Deposits on Base", href: "/wallet" },
] as const;

export default function ProfilePage() {
  const { data: user, isLoading: isUserLoading } = useGetMe();
  const { data: summary, isLoading: isSummaryLoading } = useGetDashboardSummary();
  const logoutMutation = useLogout();
  const updateProfile = useUpdateProfile();
  const queryClient = useQueryClient();
  const fileInputRef = useRef<HTMLInputElement>(null);

  const [editingName, setEditingName] = useState(false);
  const [nameDraft, setNameDraft] = useState("");
  const [profileError, setProfileError] = useState<string | null>(null);

  const invalidateUser = () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() }),
      queryClient.invalidateQueries({ queryKey: getGetProfileQueryKey() }),
    ]);

  const { uploadFile, isUploading } = useUpload({
    onSuccess: async (res) => {
      try {
        await updateProfile.mutateAsync({ data: { avatarUrl: res.objectPath } });
        await invalidateUser();
      } catch (err) {
        setProfileError(apiErrorMessage(err) ?? "Could not save profile picture.");
      }
    },
    onError: () => setProfileError("Could not upload image."),
  });

  if (isUserLoading || isSummaryLoading)
    return <div className="p-8 text-center text-ink-400">Loading profile...</div>;
  if (!user || !summary) return null;

  const address = user.walletAddress ?? "Not provisioned";

  const handleFile = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;
    if (!file.type.startsWith("image/")) {
      setProfileError("Please choose an image file.");
      return;
    }
    setProfileError(null);
    void uploadFile(file);
  };

  const startEditName = () => {
    setNameDraft(user.name);
    setEditingName(true);
    setProfileError(null);
  };

  const saveName = async () => {
    const next = nameDraft.trim();
    if (!next || next === user.name) {
      setEditingName(false);
      return;
    }
    try {
      await updateProfile.mutateAsync({ data: { name: next } });
      await invalidateUser();
      setEditingName(false);
    } catch (err) {
      setProfileError(apiErrorMessage(err) ?? "Could not update name.");
    }
  };

  return (
    <div className="mx-auto max-w-4xl space-y-6">
      <PageHeader eyebrow="Profile" title="Account & settings" />

      {/* identity card */}
      <Card className="relative overflow-hidden border-ink-900 bg-ink-950 p-6 text-white lg:p-8">
        <div
          className="pointer-events-none absolute inset-0 bg-grid-dark [background-size:32px_32px] opacity-35"
          aria-hidden
        />
        <div className="relative z-10 flex flex-wrap items-center gap-4">
          <div className="relative">
            <Avatar
              name={user.name}
              src={avatarSrc(user.avatarUrl)}
              tone="jade"
              className="h-16 w-16 text-lg"
            />
            <button
              onClick={() => fileInputRef.current?.click()}
              disabled={isUploading}
              className="absolute -bottom-1 -right-1 flex h-7 w-7 items-center justify-center rounded-full border border-white/20 bg-ink-900 text-white transition-colors hover:bg-ink-800 focus-ring disabled:opacity-60"
              aria-label="Change profile picture"
            >
              <Camera className="h-3.5 w-3.5" />
            </button>
            <input
              ref={fileInputRef}
              type="file"
              accept="image/*"
              className="hidden"
              onChange={handleFile}
            />
          </div>

          <div className="min-w-0 flex-1">
            {editingName ? (
              <div className="flex items-center gap-2">
                <input
                  value={nameDraft}
                  onChange={(e) => setNameDraft(e.target.value)}
                  autoFocus
                  onKeyDown={(e) => {
                    if (e.key === "Enter") void saveName();
                    if (e.key === "Escape") setEditingName(false);
                  }}
                  className="w-full max-w-xs rounded-lg border border-white/15 bg-white/10 px-3 py-1.5 font-display text-lg font-bold text-white outline-none placeholder:text-white/40 focus:border-jade-400/50"
                />
                <button
                  onClick={() => void saveName()}
                  disabled={updateProfile.isPending}
                  className="flex h-8 w-8 items-center justify-center rounded-lg bg-jade-500 text-white transition-colors hover:bg-jade-400 focus-ring"
                  aria-label="Save name"
                >
                  <Check className="h-4 w-4" />
                </button>
                <button
                  onClick={() => setEditingName(false)}
                  className="flex h-8 w-8 items-center justify-center rounded-lg bg-white/10 text-white transition-colors hover:bg-white/20 focus-ring"
                  aria-label="Cancel"
                >
                  <X className="h-4 w-4" />
                </button>
              </div>
            ) : (
              <div className="flex items-center gap-2">
                <h2 className="truncate font-display text-xl font-bold">{user.name}</h2>
                <button
                  onClick={startEditName}
                  className="flex h-7 w-7 shrink-0 items-center justify-center rounded-lg text-white/60 transition-colors hover:bg-white/10 hover:text-white focus-ring"
                  aria-label="Edit name"
                >
                  <Pencil className="h-3.5 w-3.5" />
                </button>
              </div>
            )}
            <p className="mt-0.5 text-sm text-white/55">{user.email}</p>
            {isUploading && <p className="mt-1 text-xs text-jade-300">Uploading picture…</p>}
          </div>
        </div>

        {profileError && (
          <p className="relative z-10 mt-4 text-sm text-red-300" role="alert">
            {profileError}
          </p>
        )}

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
          <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-ink-400">Yield APY</p>
          <p className="mt-1 font-display text-2xl font-bold text-ink-900">
            {(summary.yieldApy * 100).toFixed(1)}%
          </p>
        </Card>
      </div>

      {/* passkeys */}
      <PasskeysCard />

      {/* settings list */}
      <Card className="overflow-hidden p-1">
        <div className="divide-y divide-ink-900/[0.06]">
          {settings.map((item) => {
            const Icon = item.icon;
            return (
              <Link
                key={item.label}
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
            onSuccess: () => queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() }),
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
