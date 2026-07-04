import { useParams, useLocation } from "wouter";
import { Repeat, Calendar, Target, Sparkles, Link2, ExternalLink, Trash2 } from "lucide-react";
import { Card, Badge } from "@/components/ui";
import { BackLink } from "@/components/app/bits";
import { AmountForm } from "@/components/app/forms";
import { PrivyGoalDepositForm, PrivyGoalReleaseForm } from "@/components/app/PrivyGoalForms";
import { isWeb3Enabled } from "@/components/app/Web3Provider";
import { useOnchainConfig } from "@/lib/onchain/config";
import {
  useGetGoal,
  useGetWallet,
  useAllocateToGoal,
  useReleaseFromGoal,
  useDeleteGoal,
  getGetGoalQueryKey,
  getGetWalletQueryKey,
  getGetDashboardSummaryQueryKey,
  getListGoalsQueryKey,
  getListNotificationsQueryKey,
  getGetStreaksQueryKey,
} from "@workspace/api-client-react";
import type { ReleaseFromGoalResult } from "@workspace/api-client-react";
import { toast } from "@/hooks/use-toast";
import { formatMoney, pct, apiErrorMessage, truncateAddress } from "@/lib/utils";
import { asFrequency, buildGoalPlan, nextContribution, FREQUENCY_ADVERB, FREQUENCY_NOUN } from "@/lib/contribution-plan";
import { useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { useStepUpGate } from "@/components/app/StepUpDialog";

const EXPLORER_FALLBACK = "https://testnet.monadvision.com";

export default function GoalDetailPage() {
  const { id } = useParams();
  const [, navigate] = useLocation();
  const { data: goal, isLoading } = useGetGoal(id!, { query: { enabled: !!id, queryKey: getGetGoalQueryKey(id!) } });
  const { data: wallet } = useGetWallet();
  const { data: onchainConfig } = useOnchainConfig();

  const queryClient = useQueryClient();
  const allocateMutation = useAllocateToGoal();
  const releaseMutation = useReleaseFromGoal();
  const deleteMutation = useDeleteGoal();

  const [allocOk, setAllocOk] = useState<string | null>(null);
  const [releaseOk, setReleaseOk] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const { requestProof, stepUpDialog } = useStepUpGate();

  if (isLoading) return <div className="p-8 text-center text-muted-foreground">Loading goal…</div>;
  if (!goal) return <div className="p-8 text-center text-muted-foreground">We couldn't find that goal.</div>;

  const remaining = Math.max(0, goal.targetCents - goal.savedCents);
  const progress = pct(goal.savedCents, goal.targetCents);
  const frequency = asFrequency(goal.frequency);
  const goalPlan = buildGoalPlan(goal.targetCents, goal.createdAt, goal.deadline, frequency);
  const next = nextContribution(goalPlan.plan, goal.savedCents);
  const periodsLeft = next ? goalPlan.plan.length - next.index + 1 : 0;
  const circumference = 2 * Math.PI * 52;

  const onchain = goal.onchain ?? false;
  const feeBps = goal.feeBps ?? 0;
  const feePct = (feeBps / 100).toFixed(feeBps % 100 === 0 ? 0 : 2);
  const explorer = goal.explorerUrl ?? EXPLORER_FALLBACK;
  const history = goal.history ?? [];

  // Non-custodial (Privy) wallets can't be signed by the platform, so on-chain
  // goal deposits/withdrawals must be signed by the user in-browser and only
  // confirmed server-side. Server-custody wallets keep the server-signed paths.
  const isPrivyCustody = wallet?.custody === "privy";
  const useClientSigned = onchain && isPrivyCustody && isWeb3Enabled;
  const goalVault = onchainConfig?.goalVault ?? goal.vaultAddress ?? null;
  const usdcAddress = onchainConfig?.usdc ?? null;

  const refreshGoal = () => {
    queryClient.invalidateQueries({ queryKey: getGetGoalQueryKey(goal.id) });
    queryClient.invalidateQueries({ queryKey: getGetWalletQueryKey() });
    queryClient.invalidateQueries({ queryKey: getGetDashboardSummaryQueryKey() });
    queryClient.invalidateQueries({ queryKey: getListNotificationsQueryKey() });
  };

  return (
    <div className="mx-auto max-w-4xl space-y-6">
      <BackLink href="/goals" label="Personal Savings" />

      <div className="grid gap-6 md:grid-cols-5">
        {/* progress ring */}
        <Card className="flex flex-col items-center justify-center p-8 text-center md:col-span-2">
          <span className="mb-4 flex h-14 w-14 items-center justify-center rounded-2xl bg-background text-3xl">
            {goal.emoji || "🎯"}
          </span>
          <div className="relative h-40 w-40">
            <svg viewBox="0 0 120 120" className="h-full w-full -rotate-90">
              <circle cx="60" cy="60" r="52" fill="none" stroke="#0C151212" strokeWidth="12" />
              <circle
                cx="60"
                cy="60"
                r="52"
                fill="none"
                stroke="#0E9E6E"
                strokeWidth="12"
                strokeLinecap="round"
                strokeDasharray={circumference}
                strokeDashoffset={circumference - (progress / 100) * circumference}
              />
            </svg>
            <div className="absolute inset-0 flex flex-col items-center justify-center">
              <span className="font-display text-3xl font-bold text-foreground">{progress}%</span>
              <span className="font-mono text-[10px] uppercase tracking-wide text-muted-foreground">
                saved
              </span>
            </div>
          </div>
          <h1 className="mt-5 font-display text-xl font-bold text-foreground">{goal.name}</h1>
          <p className="text-sm text-muted-foreground">
            {formatMoney(goal.savedCents)} of {formatMoney(goal.targetCents)}
          </p>
          {onchain && (
            <Badge tone="jade" className="mt-3 bg-jade-50 text-jade-700 ring-jade-500/20 dark:bg-jade-500/15 dark:text-jade-300">
              <Link2 className="h-3.5 w-3.5" /> On-chain
            </Badge>
          )}
        </Card>

        {/* details + actions */}
        <div className="space-y-6 md:col-span-3">
          <Card className="p-6">
            <h2 className="font-display text-lg font-bold text-foreground">Add money</h2>
            <p className="mt-1 text-sm text-muted-foreground">
              {onchain
                ? "Move funds from your available balance into this goal's on-chain vault. Deposits are free."
                : "Move funds from your available balance into this allocation."}
            </p>
            <div className="mt-4">
              {useClientSigned ? (
                <PrivyGoalDepositForm
                  goalId={goal.id}
                  goalVault={goalVault}
                  usdcAddress={usdcAddress}
                  presets={[1000, 2500, 5000]}
                  onSuccess={() => {
                    refreshGoal();
                    queryClient.invalidateQueries({ queryKey: getGetStreaksQueryKey() });
                    toast({
                      title: "Streak kept alive 🔥",
                      description: "Nice, that deposit counts toward your savings streak.",
                    });
                  }}
                />
              ) : (
                <AmountForm
                  onSubmit={(amountCents) => {
                    setAllocOk(null);
                    allocateMutation.mutate({ id: goal.id, data: { amountCents } }, {
                      onSuccess: () => {
                        refreshGoal();
                        setAllocOk("Funds added to goal");
                        queryClient.invalidateQueries({ queryKey: getGetStreaksQueryKey() });
                        toast({
                          title: "Streak kept alive 🔥",
                          description: "Nice, that deposit counts toward your savings streak.",
                        });
                      }
                    });
                  }}
                  presets={[1000, 2500, 5000]}
                  submitLabel="Add funds"
                  pending={allocateMutation.isPending}
                  error={apiErrorMessage(allocateMutation.error)}
                  ok={allocOk}
                />
              )}
            </div>
            <div className="mt-5 border-t border-border pt-5">
              <p className="mb-1 text-sm font-medium text-foreground">Withdraw</p>
              {onchain && feeBps > 0 && (
                <p className="mb-3 text-xs text-muted-foreground">
                  A {feePct}% withdrawal fee is taken on-chain. You receive the amount net of the fee.
                </p>
              )}
              {useClientSigned ? (
                <>
                  <PrivyGoalReleaseForm
                    goalId={goal.id}
                    goalVault={goalVault}
                    onSuccess={(res: ReleaseFromGoalResult) => {
                      refreshGoal();
                      setReleaseOk(
                        res.feeCents > 0
                          ? `${formatMoney(res.netCents)} released (after a ${formatMoney(res.feeCents)} fee)`
                          : `${formatMoney(res.netCents)} released to available`,
                      );
                    }}
                  />
                  {releaseOk && (
                    <p className="mt-2 text-sm text-jade-600 dark:text-jade-400">{releaseOk}</p>
                  )}
                </>
              ) : (
                <AmountForm
                  onSubmit={async (amountCents) => {
                    setReleaseOk(null);
                    // Withdrawing moves real funds out of the on-chain vault —
                    // confirm it's really you before we move anything.
                    const proof = await requestProof();
                    if (!proof) return;
                    releaseMutation.mutate({ id: goal.id, data: { amountCents, ...proof } }, {
                      onSuccess: (res) => {
                        refreshGoal();
                        setReleaseOk(
                          res.feeCents > 0
                            ? `${formatMoney(res.netCents)} released (after a ${formatMoney(res.feeCents)} fee)`
                            : `${formatMoney(res.netCents)} released to available`,
                        );
                      }
                    });
                  }}
                  submitLabel="Withdraw to available"
                  variant="secondary"
                  pending={releaseMutation.isPending}
                  error={apiErrorMessage(releaseMutation.error)}
                  ok={releaseOk}
                />
              )}
            </div>
          </Card>

          <div className="grid gap-4 sm:grid-cols-2">
            <Card className="p-5">
              <div className="flex items-center gap-2 text-jade-600 dark:text-jade-400">
                <Target className="h-4 w-4" />
                <p className="font-mono text-[10px] uppercase tracking-[0.15em]">Remaining</p>
              </div>
              <p className="mt-1.5 font-display text-xl font-bold text-foreground">
                {formatMoney(remaining)}
              </p>
            </Card>
            <Card className="p-5">
              <div className="flex items-center gap-2 text-jade-600 dark:text-jade-400">
                <Calendar className="h-4 w-4" />
                <p className="font-mono text-[10px] uppercase tracking-[0.15em]">Target date</p>
              </div>
              <p className="mt-1.5 font-display text-xl font-bold text-foreground">
                {new Date(goal.deadline).toLocaleDateString("en-US", {
                  month: "short",
                  day: "numeric",
                  year: "numeric",
                })}
              </p>
            </Card>
          </div>

          <Card className="p-5">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-3">
                <span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-jade-50 text-jade-600 dark:bg-jade-500/15 dark:text-jade-300">
                  <Repeat className="h-5 w-5" />
                </span>
                <div>
                  <p className="font-semibold text-foreground">Contribution plan</p>
                  <p className="text-sm text-muted-foreground capitalize">{FREQUENCY_ADVERB[frequency]} · grows gradually</p>
                </div>
              </div>
              {next ? <Badge tone="jade">Step {next.index}/{next.total}</Badge> : <Badge tone="jade">Complete</Badge>}
            </div>
            {next ? (
              <div className="mt-4 flex items-end justify-between border-t border-border pt-4">
                <div>
                  <p className="font-mono text-[10px] uppercase tracking-[0.15em] text-muted-foreground">
                    Next contribution
                  </p>
                  <p className="mt-1 font-display text-2xl font-bold text-foreground">
                    {formatMoney(next.amountCents)}
                  </p>
                </div>
                <p className="text-sm text-muted-foreground">
                  this {FREQUENCY_NOUN[frequency]}
                </p>
              </div>
            ) : (
              <p className="mt-4 border-t border-border pt-4 text-sm text-muted-foreground">
                You&apos;ve completed every step of your plan. 🎉
              </p>
            )}
          </Card>

          {next && remaining > 0 && (
            <p className="flex items-center justify-center gap-2 text-center text-sm text-muted-foreground">
              <Sparkles className="h-4 w-4 text-jade-500" />
              Keep going {FREQUENCY_ADVERB[frequency]}. About{" "}
              <span className="font-semibold text-foreground">
                {periodsLeft} {FREQUENCY_NOUN[frequency]}{periodsLeft === 1 ? "" : "s"}
              </span>{" "}
              of contributions left to reach your target.
            </p>
          )}

          {onchain && goal.vaultAddress && (
            <Card className="p-6">
              <div className="flex items-center gap-2">
                <Link2 className="h-5 w-5 text-jade-600 dark:text-jade-400" />
                <h2 className="font-display text-lg font-bold text-foreground">On-chain vault</h2>
              </div>
              <p className="mt-1 text-sm text-muted-foreground">
                Funds you allocate are deposited into this vault on Monad. A {feePct}% protocol fee is
                taken on each withdrawal.
              </p>
              <a
                href={`${explorer}/address/${goal.vaultAddress}`}
                target="_blank"
                rel="noreferrer"
                className="mt-4 inline-flex items-center gap-2 rounded-xl border border-border bg-card px-3 py-2 font-mono text-xs text-foreground transition hover:border-jade-500/40 hover:text-jade-700 dark:hover:text-jade-300"
              >
                {truncateAddress(goal.vaultAddress)}
                <ExternalLink className="h-3.5 w-3.5" />
              </a>
            </Card>
          )}

          {history.length > 0 && (
            <Card className="p-6">
              <h2 className="font-display text-lg font-bold text-foreground">Activity</h2>
              <ul className="mt-4 space-y-2">
                {history.map((h) => (
                  <li
                    key={h.id}
                    className="flex items-center justify-between gap-3 rounded-2xl border border-border bg-card px-4 py-3"
                  >
                    <div className="min-w-0">
                      <p className="text-sm font-semibold capitalize text-foreground">
                        {h.type.replace(/_/g, " ")}
                      </p>
                      <p className="text-xs text-muted-foreground">{formatMoney(h.amountCents)}</p>
                    </div>
                    {h.txHash ? (
                      <a
                        href={`${explorer}/tx/${h.txHash}`}
                        target="_blank"
                        rel="noreferrer"
                        className="inline-flex items-center gap-1.5 font-mono text-xs text-jade-700 transition hover:text-jade-800 dark:text-jade-300"
                      >
                        {truncateAddress(h.txHash)}
                        <ExternalLink className="h-3.5 w-3.5" />
                      </a>
                    ) : (
                      <Badge tone="neutral" className="capitalize">{h.onchainStatus}</Badge>
                    )}
                  </li>
                ))}
              </ul>
            </Card>
          )}

          <Card className="border-rose-500/20 p-6">
            <h2 className="font-display text-lg font-bold text-foreground">Delete goal</h2>
            <p className="mt-1 text-sm text-muted-foreground">
              {goal.savedCents > 0
                ? onchain && feeBps > 0
                  ? `This withdraws the full ${formatMoney(goal.savedCents)} balance back to your available funds (minus the ${feePct}% withdrawal fee) and closes the goal.`
                  : `This returns the full ${formatMoney(goal.savedCents)} balance to your available funds and closes the goal.`
                : "This permanently closes the goal."}
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
                  <Trash2 className="h-4 w-4" /> Delete goal
                </button>
              ) : (
                <>
                  <button
                    type="button"
                    disabled={deleteMutation.isPending}
                    onClick={async () => {
                      // Deleting auto-withdraws the full balance — confirm
                      // it's really you before we move anything.
                      const proof = await requestProof();
                      if (!proof) return;
                      deleteMutation.mutate(
                        { id: goal.id, data: proof },
                        {
                          onSuccess: () => {
                            queryClient.invalidateQueries({ queryKey: getListGoalsQueryKey() });
                            queryClient.invalidateQueries({ queryKey: getGetWalletQueryKey() });
                            queryClient.invalidateQueries({ queryKey: getGetDashboardSummaryQueryKey() });
                            queryClient.invalidateQueries({ queryKey: getListNotificationsQueryKey() });
                            navigate("/goals");
                          },
                        },
                      );
                    }}
                    className="inline-flex items-center gap-2 rounded-xl bg-rose-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-rose-700 disabled:opacity-60"
                  >
                    <Trash2 className="h-4 w-4" />
                    {deleteMutation.isPending ? "Deleting…" : "Confirm delete"}
                  </button>
                  <button
                    type="button"
                    disabled={deleteMutation.isPending}
                    onClick={() => setConfirmDelete(false)}
                    className="rounded-xl border border-border bg-card px-4 py-2 text-sm font-medium text-muted-foreground transition hover:bg-accent"
                  >
                    Cancel
                  </button>
                </>
              )}
            </div>
          </Card>
        </div>
      </div>
      {stepUpDialog}
    </div>
  );
}
