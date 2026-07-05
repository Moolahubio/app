import { useState } from "react";
import { Link } from "wouter";
import { useTranslation, Trans } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import {
  Snowflake,
  Plane,
  Bell,
  Share2,
  Trophy,
  Target,
  Users,
  Settings2,
  ShieldCheck,
} from "lucide-react";
import { Card, Badge, Button } from "@/components/ui";
import { Switch } from "@/components/ui/switch";
import { PageHeader, BackLink } from "@/components/app/bits";
import { StreakFlameHero, periodNoun, streakUnit } from "@/components/app/StreakFlame";
import { StreakBadges, StreakBadgeTier } from "@/components/app/StreakBadges";
import { StreakShareCard } from "@/components/app/StreakShareCard";
import { useStreak, getGetStreaksQueryKey } from "@/hooks/use-streak";
import {
  useSetStreakReminders,
  useStartStreakVacation,
  useEndStreakVacation,
  useGetDashboardSummary,
} from "@workspace/api-client-react";
import { apiErrorMessage, formatDate } from "@/lib/utils";

const VACATION_DAYS = 14;

export default function StreaksPage() {
  const { t } = useTranslation("streak");
  const { data, isLoading } = useStreak();
  const { data: summary } = useGetDashboardSummary();
  const queryClient = useQueryClient();

  const setReminders = useSetStreakReminders();
  const startVacation = useStartStreakVacation();
  const endVacation = useEndStreakVacation();

  const [shareOpen, setShareOpen] = useState(false);

  const refresh = () => queryClient.invalidateQueries({ queryKey: getGetStreaksQueryKey() });

  if (isLoading) {
    return <div className="p-8 text-center text-muted-foreground">{t("loading")}</div>;
  }
  if (!data) return null;

  const heroCount = data.hero?.count ?? 0;
  const heroStatus = data.hero?.status ?? "broken";
  const unit = streakUnit(data.frequency, heroCount);
  const heroCaption = data.hero
    ? t("hero.captionActive", { count: heroCount, period: periodNoun(data.frequency) })
    : t("hero.captionEmpty", { period: periodNoun(data.frequency) });

  const savedAmount = summary ? summary.goalTotalCents + summary.circlePotCents : null;
  const vacation = data.vacation;

  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <BackLink href="/" label={t("common:nav.home")} />
      <PageHeader eyebrow={t("eyebrow")} title={t("title")} />

      {/* Gentle at-risk nudge — never alarming */}
      {data.atRisk && data.currentPeriodEnd && (
        <div className="flex items-start gap-3 rounded-2xl border border-jade-500/30 bg-jade-500/[0.06] p-4">
          <Bell className="mt-0.5 h-5 w-5 shrink-0 text-jade-600 dark:text-jade-400" />
          <p className="text-sm text-foreground">
            <Trans
              t={t}
              i18nKey="atRisk.message"
              values={{
                date: formatDate(data.currentPeriodEnd, {
                  weekday: "long",
                  month: "short",
                  day: "numeric",
                }),
              }}
              components={{ strong: <span className="font-semibold" /> }}
            />
          </p>
        </div>
      )}

      {/* Hero */}
      <Card className="p-8">
        <StreakFlameHero count={heroCount} status={heroStatus} caption={heroCaption} />
        <div className="mt-6 grid grid-cols-3 gap-3 border-t border-[var(--mh-border)] pt-6 text-center">
          <Stat label={t("stats.current", { unit })} value={String(heroCount)} />
          <Stat label={t("stats.lifetimeBest")} value={String(data.lifetimeBest)} />
          <Stat label={t("stats.periodsSaved")} value={String(data.totalPeriodsSaved)} />
        </div>
        <div className="mt-6 flex justify-center">
          <Button variant="secondary" onClick={() => setShareOpen(true)} disabled={heroCount === 0}>
            <Share2 className="h-4 w-4" /> {t("share.title")}
          </Button>
        </div>
      </Card>

      {/* Frequency + where saves count */}
      <Card className="p-6">
        <div className="flex items-center justify-between gap-4">
          <div>
            <p className="font-semibold text-foreground">
              {t("card.streakTitle", { frequency: t(`frequencyName.${data.frequency}`) })}
            </p>
            <p className="mt-0.5 text-sm text-muted-foreground">
              {t("card.oneDepositPer", { period: periodNoun(data.frequency) })}
            </p>
          </div>
          <Link href="/profile/streak">
            <Button variant="secondary" size="sm">
              <Settings2 className="h-4 w-4" /> {t("card.change")}
            </Button>
          </Link>
        </div>
        <div className="mt-4 grid gap-3 sm:grid-cols-2">
          <div className="mh-glass flex items-center gap-3 rounded-2xl px-4 py-3">
            <span className="flex h-9 w-9 items-center justify-center rounded-xl bg-jade-500/15 text-jade-600 dark:text-jade-400">
              <Target className="h-5 w-5" />
            </span>
            <p className="text-sm text-[var(--mh-muted)]">{t("card.goalDepositsCount")}</p>
          </div>
          <div className="mh-glass flex items-center gap-3 rounded-2xl px-4 py-3">
            <span className="flex h-9 w-9 items-center justify-center rounded-xl bg-jade-500/15 text-jade-600 dark:text-jade-400">
              <Users className="h-5 w-5" />
            </span>
            <p className="text-sm text-[var(--mh-muted)]">{t("card.circleContributionsCount")}</p>
          </div>
        </div>
        {!data.canChangeFrequency && (
          <p className="mt-3 text-xs text-muted-foreground">
            {data.nextChangeYear
              ? t("card.changeOncePerYearNext", { year: data.nextChangeYear })
              : t("card.changeOncePerYear")}
          </p>
        )}
      </Card>

      {/* Badge tier + progress */}
      <Card className="p-6">
        <div className="mb-4 flex items-center gap-2">
          <Trophy className="h-5 w-5 text-amber-500" />
          <h2 className="font-display text-lg font-bold text-foreground">{t("badges.title")}</h2>
        </div>
        <StreakBadgeTier progress={data.badgeProgress} />
        <div className="mt-5">
          <StreakBadges badges={data.badges} />
        </div>
      </Card>

      {/* Freezes */}
      <Card className="p-6">
        <div className="flex items-center gap-2">
          <Snowflake className="h-5 w-5 text-sky-500" />
          <h2 className="font-display text-lg font-bold text-foreground">{t("freezes.title")}</h2>
        </div>
        <p className="mt-1 text-sm text-muted-foreground">{t("freezes.description")}</p>
        <div className="mt-4 flex items-center gap-2">
          {Array.from({ length: 4 }).map((_, i) => (
            <span
              key={i}
              className={`flex h-10 w-10 items-center justify-center rounded-2xl ${
                i < data.freezes.balance ? "bg-sky-500/15 text-sky-500" : "bg-muted text-muted-foreground/40"
              }`}
            >
              <Snowflake className="h-5 w-5" />
            </span>
          ))}
          <span className="ms-2 text-sm text-muted-foreground">
            {t("freezes.available", { count: data.freezes.balance })}
          </span>
        </div>
      </Card>

      {/* Reminders */}
      <Card className="p-6">
        <div className="flex items-center justify-between gap-4">
          <div className="flex items-start gap-3">
            <Bell className="mt-0.5 h-5 w-5 text-jade-600 dark:text-jade-400" />
            <div>
              <p className="font-semibold text-foreground">{t("reminders.title")}</p>
              <p className="text-sm text-muted-foreground">
                {t("reminders.description", { period: periodNoun(data.frequency) })}
              </p>
            </div>
          </div>
          <Switch
            checked={data.reminderOptIn}
            disabled={setReminders.isPending}
            onCheckedChange={(checked) =>
              setReminders.mutate({ data: { optIn: checked } }, { onSuccess: refresh })
            }
          />
        </div>
        {setReminders.error && (
          <p className="mt-3 text-sm text-rose-600">{apiErrorMessage(setReminders.error)}</p>
        )}
      </Card>

      {/* Vacation */}
      <Card className="p-6">
        <div className="flex items-center gap-2">
          <Plane className="h-5 w-5 text-jade-600 dark:text-jade-400" />
          <h2 className="font-display text-lg font-bold text-foreground">{t("vacation.title")}</h2>
        </div>
        <p className="mt-1 text-sm text-muted-foreground">{t("vacation.description")}</p>
        {vacation.active ? (
          <div className="mt-4 space-y-3">
            <Badge tone="sky">
              <Plane className="h-3.5 w-3.5" />{" "}
              {vacation.end
                ? t("vacation.onVacationUntil", {
                    date: formatDate(vacation.end, { month: "short", day: "numeric" }),
                  })
                : t("vacation.onVacation")}
            </Badge>
            <Button
              variant="secondary"
              onClick={() => endVacation.mutate(undefined, { onSuccess: refresh })}
              disabled={endVacation.isPending}
            >
              {endVacation.isPending ? t("vacation.ending") : t("vacation.endEarly")}
            </Button>
          </div>
        ) : (
          <div className="mt-4">
            <Button
              onClick={() =>
                startVacation.mutate({ data: { days: VACATION_DAYS } }, { onSuccess: refresh })
              }
              disabled={startVacation.isPending || vacation.usedThisYear}
            >
              <Plane className="h-4 w-4" />
              {vacation.usedThisYear
                ? t("vacation.usedThisYear")
                : startVacation.isPending
                  ? t("vacation.starting")
                  : t("vacation.startDays", { count: VACATION_DAYS })}
            </Button>
            {startVacation.error && (
              <p className="mt-3 text-sm text-rose-600">{apiErrorMessage(startVacation.error)}</p>
            )}
          </div>
        )}
      </Card>

      <p className="flex items-center justify-center gap-1.5 text-center text-xs text-muted-foreground">
        <ShieldCheck className="h-3.5 w-3.5" /> {t("footer.disclaimer")}
      </p>

      <StreakShareCard
        open={shareOpen}
        onOpenChange={setShareOpen}
        count={heroCount}
        caption={heroCaption}
        amountCents={savedAmount}
      />
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="font-display text-2xl font-bold tabular-nums text-foreground">{value}</p>
      <p className="mt-0.5 font-mono text-[10px] uppercase tracking-[0.15em] text-muted-foreground">
        {label}
      </p>
    </div>
  );
}
