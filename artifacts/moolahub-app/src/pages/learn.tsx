import { Link } from "wouter";
import { useTranslation } from "react-i18next";
import { CheckCircle2, Clock, GraduationCap, ArrowRight } from "lucide-react";
import { Badge, Eyebrow, GlassCard, ProgressLine, Skeleton, EmptyState } from "@/components/ui";
import { PageHeader } from "@/components/app/bits";
import { useListLessons } from "@workspace/api-client-react";

export default function LearnPage() {
  const { t } = useTranslation("learn");
  const { data: lessons, isLoading } = useListLessons();

  if (isLoading) {
    return (
      <div className="mx-auto max-w-6xl space-y-6">
        <PageHeader
          eyebrow={t("common:nav.learn")}
          title={t("header.title")}
          description={t("header.description")}
        />
        <Skeleton className="h-[88px]" />
        <Skeleton className="h-52" />
        <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          {Array.from({ length: 6 }).map((_, i) => (
            <Skeleton key={i} className="h-56" />
          ))}
        </div>
      </div>
    );
  }

  if (!lessons || lessons.length === 0) {
    return (
      <div className="mx-auto max-w-6xl space-y-6">
        <PageHeader
          eyebrow={t("common:nav.learn")}
          title={t("header.title")}
          description={t("header.description")}
        />
        <EmptyState
          icon={<GraduationCap className="h-6 w-6" />}
          title={t("empty")}
          description={t("header.description")}
        />
      </div>
    );
  }

  const completed = lessons.filter((l) => l.completed).length;
  const featured = lessons[0];
  const rest = lessons.slice(1);
  const progressPct = lessons.length ? (completed / lessons.length) * 100 : 0;

  return (
    <div className="mx-auto max-w-6xl space-y-6">
      <PageHeader
        eyebrow={t("common:nav.learn")}
        title={t("header.title")}
        description={t("header.description")}
      />

      <GlassCard className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex items-center gap-3">
          <span className="grid size-11 shrink-0 place-items-center rounded-2xl border border-[rgba(45,212,166,0.18)] bg-[rgba(45,212,166,0.09)] text-[var(--mh-mint)]">
            <GraduationCap className="h-6 w-6" />
          </span>
          <div>
            <p className="font-semibold text-[var(--mh-text-strong)]">
              {t("progress.count", { completed, total: lessons.length })}
            </p>
            <p className="mt-0.5 text-sm text-[var(--mh-muted)]">{t("progress.encourage")}</p>
          </div>
        </div>
        <div className="w-full sm:max-w-[220px]">
          <ProgressLine value={progressPct} />
        </div>
      </GlassCard>

      <Link href={`/learn/${featured.slug}`} className="group block focus-ring rounded-[var(--mh-radius-lg)]">
        <div className="mh-card-highlight hover-lift relative isolate overflow-hidden rounded-[var(--mh-radius-lg)] p-8 text-white transition-transform duration-150">
          <div
            className="pointer-events-none absolute inset-0 bg-grid-dark [background-size:32px_32px] opacity-25"
            aria-hidden
          />
          <Eyebrow tone="light">
            {featured.completed ? t("featured.revisit") : t("featured.startHere")}
          </Eyebrow>
          <div className="mt-4 flex items-start gap-5">
            <span className="text-5xl">{featured.emoji}</span>
            <div className="min-w-0">
              <h2 className="font-display text-2xl font-bold tracking-[-0.02em]">{featured.title}</h2>
              <p className="mt-2 max-w-lg text-white/70">{featured.summary}</p>
              <div className="mt-4 inline-flex items-center gap-1.5 text-sm font-semibold text-[#B8FFE7]">
                {featured.completed ? t("featured.reviewLesson") : t("featured.startLesson")}
                <ArrowRight className="h-4 w-4 transition-transform group-hover:translate-x-0.5 rtl:-scale-x-100" />
              </div>
            </div>
          </div>
        </div>
      </Link>

      <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
        {rest.map((lesson) => (
          <Link
            key={lesson.slug}
            href={`/learn/${lesson.slug}`}
            className="group block focus-ring rounded-[var(--mh-radius-lg)]"
          >
            <GlassCard hover className="flex h-full flex-col">
              <div className="flex items-center justify-between">
                <span className="text-3xl">{lesson.emoji}</span>
                {lesson.completed ? (
                  <Badge tone="jade">
                    <CheckCircle2 className="h-3 w-3" /> {t("card.done")}
                  </Badge>
                ) : (
                  <Badge tone="neutral">
                    <Clock className="h-3 w-3" /> {t("card.minutes", { count: lesson.minutes })}
                  </Badge>
                )}
              </div>
              <h3 className="mt-4 font-display text-lg font-bold leading-snug text-[var(--mh-text-strong)]">
                {lesson.title}
              </h3>
              <p className="mt-2 flex-1 text-sm leading-relaxed text-[var(--mh-muted)]">{lesson.summary}</p>
              <p className="mt-4 font-mono text-xs uppercase tracking-[0.15em] text-[var(--mh-muted)]">
                {lesson.category} · {lesson.level}
              </p>
            </GlassCard>
          </Link>
        ))}
      </div>
    </div>
  );
}
