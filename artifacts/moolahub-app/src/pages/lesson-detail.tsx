import { Link, useParams, useLocation } from "wouter";
import { useTranslation } from "react-i18next";
import { CheckCircle2, Clock, Lightbulb, ArrowRight, GraduationCap } from "lucide-react";
import { Badge, GlassCard, ProgressLine, Skeleton, StatusPill } from "@/components/ui";
import { BackLink } from "@/components/app/bits";
import { ActionButton } from "@/components/app/forms";
import { useGetLesson, useListLessons, useCompleteLesson, getGetLessonQueryKey, getListLessonsQueryKey } from "@workspace/api-client-react";
import { useQueryClient } from "@tanstack/react-query";

export default function LessonPage() {
  const { t } = useTranslation("learn");
  const { slug } = useParams();
  const [, setLocation] = useLocation();
  const queryClient = useQueryClient();

  const { data: lesson, isLoading } = useGetLesson(slug!, { query: { enabled: !!slug, queryKey: getGetLessonQueryKey(slug!) } });
  const { data: lessonsList } = useListLessons();
  const completeMutation = useCompleteLesson();

  if (isLoading) {
    return (
      <div className="mx-auto max-w-5xl space-y-6">
        <Skeleton className="h-6 w-32" />
        <div className="grid gap-6 lg:grid-cols-3">
          <div className="space-y-6 lg:col-span-2">
            <Skeleton className="h-40" />
            <Skeleton className="h-64" />
          </div>
          <Skeleton className="h-52" />
        </div>
      </div>
    );
  }
  if (!lesson) {
    return (
      <div className="mx-auto max-w-5xl space-y-6">
        <BackLink href="/learn" label={t("detail.allLessons")} />
        <GlassCard className="text-center text-[var(--mh-muted)]">{t("detail.notFound")}</GlassCard>
      </div>
    );
  }

  const index = lessonsList?.findIndex((l) => l.slug === slug) ?? -1;
  const next = index !== -1 && lessonsList ? lessonsList[index + 1] : undefined;
  const total = lessonsList?.length ?? 0;
  const completedCount = lessonsList?.filter((l) => l.completed).length ?? 0;
  const overallPct = total ? (completedCount / total) * 100 : 0;

  return (
    <div className="mx-auto max-w-5xl space-y-6">
      <BackLink href="/learn" label={t("detail.allLessons")} />

      <div className="grid gap-6 lg:grid-cols-3">
        <article className="space-y-6 lg:col-span-2">
          {/* Media / hero card */}
          <GlassCard className="mh-card-highlight relative isolate overflow-hidden border-transparent text-white">
            <div
              className="pointer-events-none absolute inset-0 bg-grid-dark [background-size:32px_32px] opacity-25"
              aria-hidden
            />
            <div className="flex flex-wrap items-center gap-2">
              <StatusPill tone={lesson.level === "Beginner" ? "jade" : "neutral"}>{lesson.level}</StatusPill>
              <span className="inline-flex items-center gap-1.5 text-sm text-white/70">
                <Clock className="h-4 w-4" /> {t("detail.minutesRead", { count: lesson.minutes })}
              </span>
              <span className="font-mono text-xs uppercase tracking-[0.15em] text-white/60">
                {lesson.category}
              </span>
              {lesson.completed && (
                <StatusPill tone="jade">
                  <CheckCircle2 className="h-3 w-3" /> {t("detail.completed")}
                </StatusPill>
              )}
            </div>
            <div className="mt-5 flex items-start gap-4">
              <span className="text-5xl">{lesson.emoji}</span>
              <h1 className="font-display text-3xl font-bold leading-tight tracking-[-0.02em]">
                {lesson.title}
              </h1>
            </div>
            <p className="mt-4 text-lg leading-relaxed text-white/75">{lesson.summary}</p>
          </GlassCard>

          {/* Lesson body */}
          <GlassCard className="space-y-8">
            {lesson.body.map((section) => (
              <section key={section.heading}>
                <h2 className="font-display text-xl font-bold text-[var(--mh-text-strong)]">{section.heading}</h2>
                <p className="mt-2 leading-relaxed text-[var(--mh-muted)]">{section.text}</p>
              </section>
            ))}
          </GlassCard>

          {/* Key takeaways checklist */}
          {lesson.takeaways && lesson.takeaways.length > 0 && (
            <GlassCard className="border-[rgba(45,212,166,0.24)]">
              <div className="flex items-center gap-2 text-[var(--mh-mint)]">
                <Lightbulb className="h-5 w-5" />
                <h2 className="font-display text-lg font-bold">{t("detail.keyTakeaways")}</h2>
              </div>
              <ul className="mt-4 space-y-3">
                {lesson.takeaways.map((takeaway) => (
                  <li key={takeaway} className="flex items-start gap-2.5">
                    <CheckCircle2 className="mt-0.5 h-5 w-5 shrink-0 text-[var(--mh-mint)]" />
                    <span className="text-[var(--mh-text-strong)]">{takeaway}</span>
                  </li>
                ))}
              </ul>
            </GlassCard>
          )}
        </article>

        {/* Sidebar */}
        <aside className="space-y-6">
          <GlassCard className="lg:sticky lg:top-6">
            <div className="flex items-center gap-2 text-[var(--mh-muted)]">
              <GraduationCap className="h-5 w-5" />
              <span className="mh-kicker">{t("common:nav.learn")}</span>
            </div>
            <p className="mt-3 font-semibold text-[var(--mh-text-strong)]">
              {t("progress.count", { completed: completedCount, total })}
            </p>
            <div className="mt-3">
              <ProgressLine value={overallPct} />
            </div>
            <p className="mt-3 text-sm text-[var(--mh-muted)]">{t("progress.encourage")}</p>

            <div className="mh-divider my-5" />

            {lesson.completed ? (
              <Badge tone="jade" className="px-4 py-2">
                <CheckCircle2 className="h-4 w-4" /> {t("detail.lessonCompleted")}
              </Badge>
            ) : (
              <ActionButton
                onClick={() => {
                  completeMutation.mutate({ slug: lesson.slug }, {
                    onSuccess: () => {
                      queryClient.invalidateQueries({ queryKey: getGetLessonQueryKey(lesson.slug) });
                      queryClient.invalidateQueries({ queryKey: getListLessonsQueryKey() });
                      setLocation("/learn");
                    }
                  });
                }}
                label={t("detail.markComplete")}
                pendingLabel={t("detail.saving")}
                pending={completeMutation.isPending}
                className="w-full"
              />
            )}

            {next && (
              <Link
                href={`/learn/${next.slug}`}
                className="group mt-5 flex items-center justify-between gap-3 rounded-2xl border border-[var(--mh-border)] p-3 transition-colors hover:bg-[rgba(45,212,166,0.06)] focus-ring"
              >
                <span className="min-w-0">
                  <span className="block font-mono text-[10px] uppercase tracking-wide text-[var(--mh-muted)]">
                    {t("detail.nextLesson")}
                  </span>
                  <span className="block truncate font-medium text-[var(--mh-text-strong)]">{next.title}</span>
                </span>
                <ArrowRight className="h-4 w-4 shrink-0 text-[var(--mh-muted)] transition-transform group-hover:translate-x-0.5 rtl:-scale-x-100" />
              </Link>
            )}
          </GlassCard>
        </aside>
      </div>
    </div>
  );
}
