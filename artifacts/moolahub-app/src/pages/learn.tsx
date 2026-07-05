import { Link } from "wouter";
import { useTranslation } from "react-i18next";
import { CheckCircle2, Clock, GraduationCap, ArrowRight } from "lucide-react";
import { Card, Badge, Eyebrow } from "@/components/ui";
import { PageHeader } from "@/components/app/bits";
import { useListLessons } from "@workspace/api-client-react";

export default function LearnPage() {
  const { t } = useTranslation("learn");
  const { data: lessons, isLoading } = useListLessons();

  if (isLoading) return <div className="p-8 text-center text-muted-foreground">{t("loading")}</div>;
  if (!lessons || lessons.length === 0) return <div className="p-8 text-center text-muted-foreground">{t("empty")}</div>;

  const completed = lessons.filter((l) => l.completed).length;
  const featured = lessons[0];
  const rest = lessons.slice(1);

  return (
    <div className="mx-auto max-w-6xl space-y-6">
      <PageHeader
        eyebrow={t("common:nav.learn")}
        title={t("header.title")}
        description={t("header.description")}
      />

      <Card className="flex flex-wrap items-center justify-between gap-4 p-5">
        <div className="flex items-center gap-3">
          <span className="flex h-11 w-11 items-center justify-center rounded-2xl bg-jade-50 text-jade-600 dark:bg-jade-500/15 dark:text-jade-300">
            <GraduationCap className="h-6 w-6" />
          </span>
          <div>
            <p className="font-semibold text-foreground">
              {t("progress.count", { completed, total: lessons.length })}
            </p>
            <p className="text-sm text-muted-foreground">{t("progress.encourage")}</p>
          </div>
        </div>
        <div className="flex gap-1.5">
          {lessons.map((l) => (
            <span
              key={l.slug}
              className={`h-2 w-10 rounded-full ${l.completed ? "bg-jade-500" : "bg-muted"}`}
            />
          ))}
        </div>
      </Card>

      <Link href={`/learn/${featured.slug}`} className="group block">
        <Card className="relative isolate overflow-hidden border-ink-900 bg-ink-950 p-8 text-white transition-[border-color,background-color] duration-150 group-hover:border-jade-500/30">
          <div
            className="pointer-events-none absolute inset-0 bg-grid-dark [background-size:32px_32px] opacity-30"
            aria-hidden
          />
          <Eyebrow tone="light">{featured.completed ? t("featured.revisit") : t("featured.startHere")}</Eyebrow>
          <div className="mt-4 flex items-start gap-5">
            <span className="text-5xl">{featured.emoji}</span>
            <div>
              <h2 className="font-display text-2xl font-bold">{featured.title}</h2>
              <p className="mt-2 max-w-lg text-white/60">{featured.summary}</p>
              <div className="mt-4 inline-flex items-center gap-1.5 text-sm font-semibold text-jade-400">
                {featured.completed ? t("featured.reviewLesson") : t("featured.startLesson")}
                <ArrowRight className="h-4 w-4 transition-transform group-hover:translate-x-0.5 rtl:rotate-180" />
              </div>
            </div>
          </div>
        </Card>
      </Link>

      <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
        {rest.map((lesson) => (
          <Link key={lesson.slug} href={`/learn/${lesson.slug}`} className="group block">
            <Card className="flex h-full flex-col p-6 transition-[border-color,background-color] duration-150 group-hover:border-jade-500/25 group-hover:bg-accent">
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
              <h3 className="mt-4 font-display text-lg font-bold leading-snug text-foreground">
                {lesson.title}
              </h3>
              <p className="mt-2 flex-1 text-sm leading-relaxed text-muted-foreground">{lesson.summary}</p>
              <p className="mt-4 font-mono text-xs uppercase tracking-[0.15em] text-muted-foreground">
                {lesson.category} · {lesson.level}
              </p>
            </Card>
          </Link>
        ))}
      </div>
    </div>
  );
}
