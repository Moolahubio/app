import { NextResponse } from "next/server";
import { runDailyJobs } from "@/lib/server/scheduler";

export const dynamic = "force-dynamic";

/**
 * Scheduled jobs endpoint: runs weekly goal auto-saves and contribution
 * reminders. Secure it with CRON_SECRET and call it from any scheduler
 * (Vercel Cron, GitHub Actions, cron-job.org, …):
 *
 *   curl -H "Authorization: Bearer $CRON_SECRET" https://app.moolahub.io/api/cron
 *   # or: GET /api/cron?key=$CRON_SECRET
 */
async function handle(req: Request) {
  const secret = process.env.CRON_SECRET;
  if (!secret) {
    return NextResponse.json({ error: "CRON_SECRET is not configured" }, { status: 503 });
  }
  const bearer = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  const key = bearer ?? new URL(req.url).searchParams.get("key") ?? "";
  if (key !== secret) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  try {
    const result = await runDailyJobs();
    return NextResponse.json({ ok: true, ...result });
  } catch (e) {
    console.error("[cron] failed:", e);
    return NextResponse.json({ ok: false, error: "job failed" }, { status: 500 });
  }
}

export const GET = handle;
export const POST = handle;
