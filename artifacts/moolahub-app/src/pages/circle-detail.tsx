import {
  Users,
  ShieldCheck,
  CheckCircle2,
  Circle as CircleIcon,
  CalendarClock,
  Crown,
  Mail,
  UserPlus,
  Rocket,
  Link2,
  ExternalLink,
  Trash2
} from "lucide-react";
import { Card, Badge, Avatar, GlassCard, StatusPill, ProgressLine } from "@/components/ui";
import { BackLink, Money, Addr } from "@/components/app/bits";
import { ActionButton, InviteForm } from "@/components/app/forms";
import { PrivyContributeButton } from "@/components/app/PrivyContributeButton";
import { isWeb3Enabled } from "@/components/app/Web3Provider";
import { useOnchainConfig } from "@/lib/onchain/config";
import { useGetCircle, useGetWallet, useStartCircle, useContributeToCircle, useInviteToCircle, useDeleteCircle, getGetCircleQueryKey, getListCirclesQueryKey, getGetStreaksQueryKey } from "@workspace/api-client-react";
import { toast } from "@/hooks/use-toast";
import { formatMoney, formatDate, apiErrorMessage, cn, pct } from "@/lib/utils";
import { useQueryClient } from "@tanstack/react-query";
import { useParams, useLocation } from "wouter";
import { useTranslation } from "react-i18next";
import { useState } from "react";

export default function CircleDetailPage() {
  const { t } = useTranslation("circles");
  const { id } = useParams();
  const [, navigate] = useLocation();
  const { data: circle, isLoading } = useGetCircle(id!, { query: { enabled: !!id, queryKey: getGetCircleQueryKey(id!) } });
  const { data: wallet } = useGetWallet();
  const { data: onchainConfig } = useOnchainConfig();

  const queryClient = useQueryClient();
  const startMutation = useStartCircle();
  const contributeMutation = useContributeToCircle();
  const inviteMutation = useInviteToCircle();
  const deleteMutation = useDeleteCircle();
  const [confirmDelete, setConfirmDelete] = useState(false);

  if (isLoading) return <div className="p-8 text-center text-muted-foreground">{t("detail.loading")}</div>;
  if (!circle) return <div className="p-8 text-center text-muted-foreground">{t("detail.notFound")}</div>;

  const isForming = circle.status === "forming";
  const isActive = circle.status === "active";
  const isAccumulation = circle.type === "accumulation";
  const isCreator = circle.isCreator ?? false;
  const canStart = circle.canStart ?? false;
  const canInvite = circle.canInvite ?? false;
  const canDelete = circle.canDelete ?? false;
  const canContribute = circle.canContribute ?? (isActive && circle.myContributionStatus !== "paid");

  // Non-custodial (Privy) wallets can't be signed by the platform, so on-chain
  // contributions must be signed by the user in-browser and only confirmed
  // server-side. Server-custody wallets keep the server-signed contribute path.
  const isPrivyCustody = wallet?.custody === "privy";
  const useClientSigned = isPrivyCustody && isWeb3Enabled;

  const onContributeSuccess = () => {
    queryClient.invalidateQueries({ queryKey: getGetCircleQueryKey(circle.id) });
    queryClient.invalidateQueries({ queryKey: getGetStreaksQueryKey() });
    toast({
      title: t("detail.toast.streakTitle"),
      description: t("detail.toast.streakDescription"),
    });
  };

  return (
    <div className="mx-auto max-w-5xl space-y-6">
      <BackLink href="/circles" label={t("common:nav.groupSavings")} />

      {/* ----------------------------------------------------------- header */}
      <Card className="relative isolate overflow-hidden border-0 bg-ink-950 p-6 text-white lg:p-8">
        <div className="absolute inset-0 -z-10 bg-grid-dark [background-size:32px_32px] [mask-image:radial-gradient(70%_80%_at_90%_0%,black,transparent)]" />

        <div className="flex flex-wrap items-start justify-between gap-4">
          <div className="flex items-center gap-4">
            <span className="flex h-14 w-14 items-center justify-center rounded-2xl bg-white/10">
              <Users className="h-7 w-7 text-jade-400" />
            </span>
            <div>
              <h1 className="font-display text-2xl font-bold">{circle.name}</h1>
              <p className="text-sm capitalize text-white/70">
                {t(`frequency.${circle.frequency}`, { defaultValue: circle.frequency })} · {t("card.members", { count: circle.members.length })}
                {isForming
                  ? ` · ${t("detail.formingSuffix")}`
                  : ` · ${t("card.roundOf", { current: circle.currentRound, total: circle.totalRounds })}`}
              </p>
            </div>
          </div>
          <div className="flex flex-col items-end gap-1.5">
            <Badge tone="jade" className="bg-jade-500/15 capitalize text-jade-300 ring-jade-400/20">
              {t(`status.${circle.status}`, { defaultValue: circle.status })}
            </Badge>
            <Badge tone="neutral" className="bg-white/10 text-white/70 ring-white/15">
              {isAccumulation ? t("type.accumulation") : t("type.rotation")}
            </Badge>
            {circle.contractAddress && (
              <Badge tone="jade" className="bg-jade-500/15 text-jade-300 ring-jade-400/20">
                <Link2 className="h-3.5 w-3.5" /> {t("detail.onChain")}
              </Badge>
            )}
          </div>
        </div>

        <div className="mt-6 grid grid-cols-2 gap-4 sm:grid-cols-4">
          {[
            { label: t("card.perRound"), value: <Money cents={circle.contributionCents} /> },
            { label: t("card.youReceive"), value: <Money cents={circle.payoutCents} /> },
            isAccumulation
              ? { label: t("detail.stats.rounds"), value: `${circle.totalRounds}` }
              : { label: t("detail.stats.yourPosition"), value: circle.myPayoutRound ? `#${circle.myPayoutRound}` : "—" },
            {
              label: t("detail.stats.started"),
              value: circle.startDate ? formatDate(circle.startDate, {
                month: "short",
                day: "numeric",
              }) : "—",
            },
          ].map((s) => (
            <div key={s.label}>
              <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-white/60">
                {s.label}
              </p>
              <p className="mt-1 font-display text-xl font-bold">{s.value}</p>
            </div>
          ))}
        </div>

        <div className="mt-6 flex flex-wrap items-center gap-4">
          {canContribute ? (
            useClientSigned ? (
              <PrivyContributeButton
                circleId={circle.id}
                escrow={circle.contractAddress ?? null}
                isAccumulation={isAccumulation}
                platform={onchainConfig?.platform ?? null}
                usdcAddress={onchainConfig?.usdc ?? null}
                contributionCents={circle.contributionCents}
                label={t("detail.contribute", { amount: formatMoney(circle.contributionCents) })}
                onSuccess={onContributeSuccess}
              />
            ) : (
              <ActionButton
                onClick={() => {
                  contributeMutation.mutate({ id: circle.id }, {
                    onSuccess: onContributeSuccess,
                  });
                }}
                label={t("detail.contribute", { amount: formatMoney(circle.contributionCents) })}
                pendingLabel={t("detail.submitting")}
                size="sm"
                pending={contributeMutation.isPending}
              />
            )
          ) : isActive ? (
            <Badge tone="jade" className="bg-jade-500/15 text-jade-300 ring-jade-400/20">
              <CheckCircle2 className="h-3.5 w-3.5" /> {t("detail.contributedThisRound")}
            </Badge>
          ) : (
            <Badge tone="amber">{t("detail.notStarted")}</Badge>
          )}
        </div>
        {contributeMutation.error && (
          <p className="mt-3 text-sm text-rose-300">{apiErrorMessage(contributeMutation.error)}</p>
        )}
      </Card>

      {/* ------------------------------------------------- forming controls */}
      {isForming && (
        <GlassCard>
          <div className="flex items-center gap-2">
            <UserPlus className="h-5 w-5 text-jade-600 dark:text-jade-400" />
            <h2 className="font-display text-lg font-bold text-foreground">{t("detail.build.title")}</h2>
          </div>
          <p className="mt-1 text-sm text-muted-foreground">
            {isAccumulation
              ? t("detail.build.descAccumulation", { count: circle.totalRounds })
              : circle.targetMembers
                ? t("detail.build.descTargeted", { joined: circle.members.length, target: circle.targetMembers })
                : t("detail.build.descRotation")}
          </p>

          {canInvite && (
            <div className="mt-4 max-w-md">
              <InviteForm 
                onSubmit={(email) => {
                  inviteMutation.mutate({ id: circle.id, data: { email } }, {
                    onSuccess: () => queryClient.invalidateQueries({ queryKey: getGetCircleQueryKey(circle.id) })
                  });
                }}
                pending={inviteMutation.isPending}
                ok={inviteMutation.isSuccess ? t("detail.build.sent") : null}
              />
            </div>
          )}

          {isCreator && (
            <div className="mt-6 flex flex-wrap items-center gap-3 border-t border-[var(--mh-border)] pt-5">
              {canStart ? (
                <ActionButton
                  onClick={() => {
                    startMutation.mutate({ id: circle.id }, {
                      onSuccess: () => queryClient.invalidateQueries({ queryKey: getGetCircleQueryKey(circle.id) })
                    });
                  }}
                  label={t("detail.build.start")}
                  pendingLabel={t("detail.build.starting")}
                  pending={startMutation.isPending}
                />
              ) : (
                <p className="inline-flex items-center gap-2 text-sm text-muted-foreground">
                  <Rocket className="h-4 w-4 text-muted-foreground" />
                  {t("detail.build.needMore")}
                </p>
              )}
            </div>
          )}
        </GlassCard>
      )}

      {/* ----------------------------------------------------- delete circle */}
      {canDelete && (
        <GlassCard className="border-rose-500/20">
          <h2 className="font-display text-lg font-bold text-foreground">{t("detail.delete.title")}</h2>
          <p className="mt-1 text-sm text-muted-foreground">
            {t("detail.delete.description")}
          </p>
          {deleteMutation.error && (
            <p className="mt-3 text-sm text-rose-600">{apiErrorMessage(deleteMutation.error)}</p>
          )}
          <div className="mt-4 flex flex-wrap items-center gap-3">
            {!confirmDelete ? (
              <button
                type="button"
                onClick={() => setConfirmDelete(true)}
                className="inline-flex items-center gap-2 rounded-xl border border-rose-500/30 bg-card px-4 py-2 text-sm font-medium text-rose-600 transition hover:bg-rose-50"
              >
                <Trash2 className="h-4 w-4" /> {t("detail.delete.title")}
              </button>
            ) : (
              <>
                <button
                  type="button"
                  disabled={deleteMutation.isPending}
                  onClick={() =>
                    deleteMutation.mutate(
                      { id: circle.id },
                      {
                        onSuccess: () => {
                          queryClient.invalidateQueries({ queryKey: getListCirclesQueryKey() });
                          navigate("/circles");
                        },
                      },
                    )
                  }
                  className="inline-flex items-center gap-2 rounded-xl bg-rose-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-rose-700 disabled:opacity-60"
                >
                  <Trash2 className="h-4 w-4" />
                  {deleteMutation.isPending ? t("detail.delete.deleting") : t("detail.delete.confirm")}
                </button>
                <button
                  type="button"
                  disabled={deleteMutation.isPending}
                  onClick={() => setConfirmDelete(false)}
                  className="rounded-xl border border-border bg-card px-4 py-2 text-sm font-medium text-muted-foreground transition hover:bg-accent"
                >
                  {t("common:actions.cancel")}
                </button>
              </>
            )}
          </div>
        </GlassCard>
      )}

      <div className="grid gap-6 lg:grid-cols-5">
        {/* ------------------------------------------------ payout schedule */}
        <GlassCard className="lg:col-span-3">
          <div className="flex items-center gap-2">
            <CalendarClock className="h-5 w-5 text-jade-600 dark:text-jade-400" />
            <h2 className="font-display text-lg font-bold text-foreground">
              {isAccumulation ? t("detail.schedule.membersTitle") : t("detail.schedule.payoutTitle")}
            </h2>
          </div>
          <p className="mt-1 text-sm text-muted-foreground">
            {isAccumulation
              ? t("detail.schedule.descAccumulation", { count: circle.totalRounds })
              : t("detail.schedule.descRotation")}
          </p>

          <ol className="mt-5 space-y-2">
            {circle.members.map((m) => {
              const done = m.paidOut;
              const current = !isAccumulation && isActive && circle.currentRound === m.payoutRound;
              const isYou = m.payoutRound === circle.myPayoutRound;

              return (
                <li
                  key={m.id}
                  className={cn(
                    "flex items-center gap-3 rounded-2xl border px-4 py-3",
                    current ? "border-jade-500/30 bg-jade-50 dark:bg-jade-500/15" : "border-[var(--mh-border)] bg-[var(--mh-track)]",
                  )}
                >
                  {!isAccumulation && (
                    <span className="font-mono text-xs text-muted-foreground">{m.payoutRound}</span>
                  )}
                  {done ? (
                    <CheckCircle2 className="h-5 w-5 text-jade-500" />
                  ) : current ? (
                    <Crown className="h-5 w-5 text-jade-600 dark:text-jade-400" />
                  ) : (
                    <CircleIcon className="h-5 w-5 text-muted-foreground" />
                  )}
                  <Avatar name={m.name} tone={isYou ? "jade" : "ink"} className="h-8 w-8" />
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-semibold text-foreground">
                      {m.name} {isYou && <span className="text-jade-600 dark:text-jade-400">{t("detail.schedule.you")}</span>}
                    </p>
                    <p className="text-xs text-muted-foreground capitalize">
                      {isAccumulation
                        ? done
                          ? t("detail.schedule.savingsReturned")
                          : t("detail.schedule.saving")
                        : done
                          ? t("detail.schedule.receivedPot")
                          : current
                            ? t("detail.schedule.receivingNow")
                            : m.state}
                    </p>
                  </div>
                  {current && <StatusPill tone="jade">{t("detail.schedule.current")}</StatusPill>}
                </li>
              );
            })}
          </ol>
        </GlassCard>

        {/* ------------------------------------------ contribution history */}
        <div className="space-y-6 lg:col-span-2">
          <GlassCard>
            <h2 className="font-display text-lg font-bold text-foreground">{t("detail.progress.title")}</h2>
            <p className="mt-3 text-sm text-muted-foreground">
              {t("detail.progress.roundsOf", { current: circle.currentRound, total: circle.totalRounds })}
            </p>
            <ProgressLine value={pct(circle.currentRound, circle.totalRounds)} className="mt-2" />
          </GlassCard>

          {circle.contractAddress && (
            <GlassCard>
              <div className="flex items-center gap-2">
                <Link2 className="h-5 w-5 text-jade-600 dark:text-jade-400" />
                <h2 className="font-display text-lg font-bold text-foreground">{t("detail.escrow.title")}</h2>
              </div>
              <p className="mt-1 text-sm text-muted-foreground">
                {t("detail.escrow.description", { fee: ((circle.feeBps ?? 0) / 100).toFixed(0) })}
              </p>
              <a
                href={`${circle.explorerUrl ?? "https://testnet.monadvision.com"}/address/${circle.contractAddress}`}
                target="_blank"
                rel="noreferrer"
                className="mt-4 inline-flex items-center gap-2 rounded-xl border border-[var(--mh-border)] bg-[var(--mh-track)] px-3 py-2 font-mono text-xs text-foreground transition hover:border-jade-500/40 hover:text-jade-700 focus-ring"
              >
                <Addr address={circle.contractAddress} />
                <ExternalLink className="h-3.5 w-3.5" />
              </a>
            </GlassCard>
          )}

          {(circle.history?.length ?? 0) > 0 && (
            <GlassCard>
              <h2 className="font-display text-lg font-bold text-foreground">{t("detail.history.title")}</h2>
              <ul className="mt-4 space-y-2">
                {circle.history!.map((h) => (
                  <li
                    key={h.id}
                    className="flex items-center justify-between gap-3 rounded-2xl border border-[var(--mh-border)] bg-[var(--mh-track)] px-4 py-3"
                  >
                    <div className="min-w-0">
                      <p className="text-sm font-semibold text-foreground">{t("detail.history.round", { round: h.round })}</p>
                      <p className="text-xs text-muted-foreground"><Money cents={h.amountCents} /></p>
                    </div>
                    {h.txHash ? (
                      <a
                        href={`${circle.explorerUrl ?? "https://testnet.monadvision.com"}/tx/${h.txHash}`}
                        target="_blank"
                        rel="noreferrer"
                        className="inline-flex items-center gap-1.5 font-mono text-xs text-jade-700 dark:text-jade-300 transition hover:text-jade-800"
                      >
                        <Addr address={h.txHash} />
                        <ExternalLink className="h-3.5 w-3.5" />
                      </a>
                    ) : (
                      <Badge tone="neutral" className="capitalize">{h.status}</Badge>
                    )}
                  </li>
                ))}
              </ul>
            </GlassCard>
          )}
        </div>
      </div>
    </div>
  );
}
