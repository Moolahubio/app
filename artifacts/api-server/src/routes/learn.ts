import { Router, type IRouter } from "express";
import { eq, and } from "drizzle-orm";
import { db, lessonProgressTable } from "@workspace/db";
import {
  GetLessonParams,
  CompleteLessonParams,
  ListLessonsResponse,
  GetLessonResponse,
  CompleteLessonResponse,
} from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import { requireAllowedOrigin } from "../lib/origins";
import { LESSONS } from "../lib/lessons-data";

const router: IRouter = Router();

router.get("/learn/lessons", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;

  const progress = await db
    .select()
    .from(lessonProgressTable)
    .where(eq(lessonProgressTable.userId, user.id));

  const completedSlugs = new Set(
    progress.filter((p) => p.completed).map((p) => p.lessonSlug)
  );

  const result = LESSONS.map((l) => ({
    slug: l.slug,
    title: l.title,
    summary: l.summary,
    minutes: l.minutes,
    level: l.level,
    category: l.category,
    emoji: l.emoji,
    completed: completedSlugs.has(l.slug),
  }));

  res.json(ListLessonsResponse.parse(result));
});

router.get("/learn/lessons/:slug", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawSlug = Array.isArray(req.params.slug) ? req.params.slug[0] : req.params.slug;
  const params = GetLessonParams.safeParse({ slug: rawSlug });
  if (!params.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  const lesson = LESSONS.find((l) => l.slug === params.data.slug);
  if (!lesson) {
    res.status(404).json({ error: "Lesson not found" });
    return;
  }

  const [progress] = await db
    .select()
    .from(lessonProgressTable)
    .where(
      and(
        eq(lessonProgressTable.userId, user.id),
        eq(lessonProgressTable.lessonSlug, params.data.slug)
      )
    );

  res.json(
    GetLessonResponse.parse({
      ...lesson,
      completed: progress?.completed ?? false,
    })
  );
});

router.post("/learn/lessons/:slug/complete", requireAllowedOrigin, requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rawSlug = Array.isArray(req.params.slug) ? req.params.slug[0] : req.params.slug;
  const params = CompleteLessonParams.safeParse({ slug: rawSlug });
  if (!params.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  const lesson = LESSONS.find((l) => l.slug === params.data.slug);
  if (!lesson) {
    res.status(404).json({ error: "Lesson not found" });
    return;
  }

  const [existing] = await db
    .select()
    .from(lessonProgressTable)
    .where(
      and(
        eq(lessonProgressTable.userId, user.id),
        eq(lessonProgressTable.lessonSlug, params.data.slug)
      )
    );

  if (existing) {
    await db
      .update(lessonProgressTable)
      .set({ completed: true, completedAt: new Date() })
      .where(eq(lessonProgressTable.id, existing.id));
  } else {
    await db.insert(lessonProgressTable).values({
      userId: user.id,
      lessonSlug: params.data.slug,
      completed: true,
      completedAt: new Date(),
    });
  }

  res.json(CompleteLessonResponse.parse({ ok: true }));
});

export default router;
