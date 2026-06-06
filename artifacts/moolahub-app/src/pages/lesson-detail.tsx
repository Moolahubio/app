import { Link, useParams, useLocation } from "wouter";
import { CheckCircle2, Clock, Lightbulb, ArrowRight } from "lucide-react";
import { Card, Badge } from "@/components/ui";
import { BackLink } from "@/components/app/bits";
import { ActionButton } from "@/components/app/forms";
import { useGetLesson, useListLessons, useCompleteLesson, getGetLessonQueryKey, getListLessonsQueryKey } from "@workspace/api-client-react";
import { useQueryClient } from "@tanstack/react-query";

export default function LessonPage() {
  const { slug } = useParams();
  const [, setLocation] = useLocation();
  const queryClient = useQueryClient();

  const { data: lesson, isLoading } = useGetLesson(slug!, { query: { enabled: !!slug, queryKey: getGetLessonQueryKey(slug!) } });
  const { data: lessonsList } = useListLessons();
  const completeMutation = useCompleteLesson();

  if (isLoading) return <div className="p-8 text-center text-muted-foreground">Loading lesson...</div>;
  if (!lesson) return <div className="p-8 text-center text-muted-foreground">Lesson not found</div>;

  const index = lessonsList?.findIndex((l) => l.slug === slug) ?? -1;
  const next = index !== -1 && lessonsList ? lessonsList[index + 1] : undefined;

  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <BackLink href="/learn" label="All lessons" />

      <article>
        <div className="flex items-center gap-3">
          <Badge tone={lesson.level === "Beginner" ? "jade" : "sky"}>{lesson.level}</Badge>
          <span className="inline-flex items-center gap-1.5 text-sm text-muted-foreground">
            <Clock className="h-4 w-4" /> {lesson.minutes} min read
          </span>
          <span className="font-mono text-xs uppercase tracking-[0.15em] text-muted-foreground">
            {lesson.category}
          </span>
          {lesson.completed && (
            <Badge tone="jade">
              <CheckCircle2 className="h-3 w-3" /> Completed
            </Badge>
          )}
        </div>

        <div className="mt-5 flex items-start gap-4">
          <span className="text-5xl">{lesson.emoji}</span>
          <h1 className="font-display text-3xl font-bold leading-tight tracking-tight text-foreground">
            {lesson.title}
          </h1>
        </div>
        <p className="mt-4 text-lg leading-relaxed text-muted-foreground">{lesson.summary}</p>

        <div className="mt-8 space-y-8">
          {lesson.body.map((section) => (
            <section key={section.heading}>
              <h2 className="font-display text-xl font-bold text-foreground">{section.heading}</h2>
              <p className="mt-2 leading-relaxed text-muted-foreground">{section.text}</p>
            </section>
          ))}
        </div>

        {lesson.takeaways && lesson.takeaways.length > 0 && (
          <Card className="mt-10 border-jade-500/15 bg-jade-50/50 p-6 dark:bg-jade-500/15">
            <div className="flex items-center gap-2 text-jade-700 dark:text-jade-300">
              <Lightbulb className="h-5 w-5" />
              <h2 className="font-display text-lg font-bold">Key takeaways</h2>
            </div>
            <ul className="mt-4 space-y-3">
              {lesson.takeaways.map((t) => (
                <li key={t} className="flex items-start gap-2.5">
                  <CheckCircle2 className="mt-0.5 h-5 w-5 shrink-0 text-jade-500" />
                  <span className="text-foreground">{t}</span>
                </li>
              ))}
            </ul>
          </Card>
        )}

        <div className="mt-8 flex flex-wrap items-center justify-between gap-4">
          {lesson.completed ? (
            <Badge tone="jade" className="px-4 py-2">
              <CheckCircle2 className="h-4 w-4" /> Lesson completed
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
              label="Mark complete"
              pendingLabel="Saving…"
              pending={completeMutation.isPending}
            />
          )}
          {next && (
            <Link
              href={`/learn/${next.slug}`}
              className="group inline-flex items-center gap-2 text-sm font-medium text-muted-foreground hover:text-foreground"
            >
              <span className="text-right">
                <span className="block font-mono text-[10px] uppercase tracking-wide text-muted-foreground">
                  Next lesson
                </span>
                {next.title}
              </span>
              <ArrowRight className="h-4 w-4 transition-transform group-hover:translate-x-0.5" />
            </Link>
          )}
        </div>
      </article>
    </div>
  );
}
