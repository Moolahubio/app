import Link from "next/link";
import { notFound } from "next/navigation";
import { CheckCircle2, Clock, Lightbulb, ArrowRight } from "lucide-react";
import { Card, Button, Badge } from "@/components/ui";
import { BackLink } from "@/components/app/bits";
import { lessons } from "@/lib/data";

export function generateStaticParams() {
  return lessons.map((l) => ({ slug: l.slug }));
}

export default async function LessonPage({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
  const lesson = lessons.find((l) => l.slug === slug);
  if (!lesson) notFound();

  const index = lessons.findIndex((l) => l.slug === slug);
  const next = lessons[index + 1];

  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <BackLink href="/learn" label="All lessons" />

      <article>
        <div className="flex items-center gap-3">
          <Badge tone={lesson.level === "Beginner" ? "jade" : "sky"}>{lesson.level}</Badge>
          <span className="inline-flex items-center gap-1.5 text-sm text-ink-500">
            <Clock className="h-4 w-4" /> {lesson.minutes} min read
          </span>
          <span className="font-mono text-xs uppercase tracking-[0.15em] text-ink-400">
            {lesson.category}
          </span>
        </div>

        <div className="mt-5 flex items-start gap-4">
          <span className="text-5xl">{lesson.emoji}</span>
          <h1 className="font-display text-3xl font-bold leading-tight tracking-tight text-ink-900">
            {lesson.title}
          </h1>
        </div>
        <p className="mt-4 text-lg leading-relaxed text-ink-500">{lesson.summary}</p>

        <div className="mt-8 space-y-8">
          {lesson.body.map((section) => (
            <section key={section.heading}>
              <h2 className="font-display text-xl font-bold text-ink-900">{section.heading}</h2>
              <p className="mt-2 leading-relaxed text-ink-600">{section.text}</p>
            </section>
          ))}
        </div>

        {/* takeaways */}
        <Card className="mt-10 border-jade-500/15 bg-jade-50/50 p-6">
          <div className="flex items-center gap-2 text-jade-700">
            <Lightbulb className="h-5 w-5" />
            <h2 className="font-display text-lg font-bold">Key takeaways</h2>
          </div>
          <ul className="mt-4 space-y-3">
            {lesson.takeaways.map((t) => (
              <li key={t} className="flex items-start gap-2.5">
                <CheckCircle2 className="mt-0.5 h-5 w-5 shrink-0 text-jade-500" />
                <span className="text-ink-700">{t}</span>
              </li>
            ))}
          </ul>
        </Card>

        <div className="mt-8 flex flex-wrap items-center justify-between gap-4">
          <Button variant="primary">
            <CheckCircle2 className="h-4 w-4" />
            {lesson.completed ? "Completed" : "Mark complete"}
          </Button>
          {next && (
            <Link
              href={`/learn/${next.slug}`}
              className="group inline-flex items-center gap-2 text-sm font-medium text-ink-600 hover:text-ink-900"
            >
              <span className="text-right">
                <span className="block font-mono text-[10px] uppercase tracking-wide text-ink-400">
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
