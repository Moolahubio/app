import "server-only";
import { db } from "@/lib/db";
import { lessons, getLesson } from "@/lib/content/lessons";

export async function getLessonsForUser(userId: string) {
  const progress = await db.lessonProgress.findMany({
    where: { userId },
    select: { slug: true },
  });
  const done = new Set(progress.map((p) => p.slug));
  return lessons.map((l) => ({ ...l, completed: done.has(l.slug) }));
}

export async function getLessonForUser(userId: string, slug: string) {
  const lesson = getLesson(slug);
  if (!lesson) return null;
  const progress = await db.lessonProgress.findUnique({
    where: { userId_slug: { userId, slug } },
  });
  return { ...lesson, completed: Boolean(progress) };
}
