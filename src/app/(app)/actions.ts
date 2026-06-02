"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { db } from "@/lib/db";
import { requireUser, destroySession } from "@/lib/server/auth";
import { deposit, withdraw } from "@/lib/server/deposits";
import { createGoal, allocateToGoal, releaseFromGoal } from "@/lib/server/goals";
import {
  contribute,
  inviteToCircle,
  acceptInvite,
  declineInvite,
  startCircle,
} from "@/lib/server/circles";
import { markAllRead } from "@/lib/server/notifications";

export type ActionState = { ok?: boolean; error?: string };

function toCents(raw: FormDataEntryValue | null): number {
  const n = Number(String(raw ?? "").replace(/[^0-9.]/g, ""));
  if (!Number.isFinite(n) || n <= 0) throw new Error("Enter a valid amount.");
  return Math.round(n * 100);
}

function fail(e: unknown): ActionState {
  return { error: e instanceof Error ? e.message : "Something went wrong." };
}

export async function logoutAction() {
  await destroySession();
  redirect("/login");
}

export async function depositAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const user = await requireUser();
  try {
    await deposit(user.id, toCents(formData.get("amount")));
  } catch (e) {
    return fail(e);
  }
  revalidatePath("/");
  revalidatePath("/activity");
  return { ok: true };
}

export async function withdrawAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const user = await requireUser();
  try {
    await withdraw(user.id, toCents(formData.get("amount")));
  } catch (e) {
    return fail(e);
  }
  revalidatePath("/");
  revalidatePath("/activity");
  return { ok: true };
}

export async function createGoalAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const user = await requireUser();
  try {
    const name = String(formData.get("name") ?? "").trim();
    if (!name) throw new Error("Give your goal a name.");
    const deadlineRaw = String(formData.get("deadline") ?? "");
    const deadline = deadlineRaw ? new Date(deadlineRaw) : new Date(Date.now() + 1000 * 60 * 60 * 24 * 90);
    const autoRaw = String(formData.get("autoSave") ?? "").trim();
    await createGoal(user.id, {
      name,
      emoji: String(formData.get("emoji") ?? "🎯") || "🎯",
      targetCents: toCents(formData.get("target")),
      deadline,
      autoSaveCents: autoRaw ? Math.round(Number(autoRaw) * 100) : null,
      color: String(formData.get("color") ?? "jade") || "jade",
    });
  } catch (e) {
    return fail(e);
  }
  revalidatePath("/goals");
  revalidatePath("/");
  redirect("/goals");
}

export async function allocateGoalAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const user = await requireUser();
  const goalId = String(formData.get("goalId") ?? "");
  try {
    await allocateToGoal(user.id, goalId, toCents(formData.get("amount")));
  } catch (e) {
    return fail(e);
  }
  revalidatePath(`/goals/${goalId}`);
  revalidatePath("/goals");
  revalidatePath("/");
  return { ok: true };
}

export async function releaseGoalAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const user = await requireUser();
  const goalId = String(formData.get("goalId") ?? "");
  try {
    await releaseFromGoal(user.id, goalId, toCents(formData.get("amount")));
  } catch (e) {
    return fail(e);
  }
  revalidatePath(`/goals/${goalId}`);
  revalidatePath("/goals");
  revalidatePath("/");
  return { ok: true };
}

export async function contributeAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const user = await requireUser();
  const circleId = String(formData.get("circleId") ?? "");
  try {
    await contribute(user.id, circleId);
  } catch (e) {
    return fail(e);
  }
  revalidatePath(`/circles/${circleId}`);
  revalidatePath("/circles");
  revalidatePath("/");
  return { ok: true };
}

export async function createCircleAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const user = await requireUser();
  let circleId: string;
  try {
    const name = String(formData.get("name") ?? "").trim();
    if (!name) throw new Error("Give your circle a name.");
    const frequency = String(formData.get("frequency") ?? "monthly");
    const start = new Date();
    start.setDate(start.getDate() + 7);
    // Rounds == members; starts at 1 (just the creator) and grows as people join.
    const circle = await db.circle.create({
      data: {
        name,
        status: "forming",
        contributionCents: toCents(formData.get("contribution")),
        frequency,
        totalRounds: 1,
        currentRound: 0,
        startDate: start,
        createdById: user.id,
        members: { create: { userId: user.id, position: 1, payoutRound: 1 } },
      },
    });
    circleId = circle.id;
  } catch (e) {
    return fail(e);
  }
  revalidatePath("/circles");
  redirect(`/circles/${circleId}`);
}

export async function inviteMemberAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const user = await requireUser();
  const circleId = String(formData.get("circleId") ?? "");
  try {
    await inviteToCircle(user.id, circleId, String(formData.get("email") ?? ""));
  } catch (e) {
    return fail(e);
  }
  revalidatePath(`/circles/${circleId}`);
  return { ok: true };
}

export async function acceptInviteAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const user = await requireUser();
  const inviteId = String(formData.get("inviteId") ?? "");
  try {
    await acceptInvite(user.id, user.email, inviteId);
  } catch (e) {
    return fail(e);
  }
  revalidatePath("/circles");
  revalidatePath("/");
  return { ok: true };
}

export async function declineInviteAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const user = await requireUser();
  try {
    await declineInvite(user.email, String(formData.get("inviteId") ?? ""));
  } catch (e) {
    return fail(e);
  }
  revalidatePath("/circles");
  return { ok: true };
}

export async function startCircleAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const user = await requireUser();
  const circleId = String(formData.get("circleId") ?? "");
  try {
    await startCircle(user.id, circleId);
  } catch (e) {
    return fail(e);
  }
  revalidatePath(`/circles/${circleId}`);
  revalidatePath("/circles");
  return { ok: true };
}

export async function markNotificationsReadAction(): Promise<void> {
  const user = await requireUser();
  await markAllRead(user.id);
}

export async function completeLessonAction(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const user = await requireUser();
  const slug = String(formData.get("slug") ?? "");
  try {
    await db.lessonProgress.upsert({
      where: { userId_slug: { userId: user.id, slug } },
      update: {},
      create: { userId: user.id, slug },
    });
  } catch (e) {
    return fail(e);
  }
  revalidatePath(`/learn/${slug}`);
  revalidatePath("/learn");
  return { ok: true };
}

/** Demo KYC: marks the user verified (stands in for the Yellowcard flow). */
export async function verifyKycAction(): Promise<void> {
  const user = await requireUser();
  await db.user.update({ where: { id: user.id }, data: { kycStatus: "verified" } });
  revalidatePath("/profile");
  revalidatePath("/wallet");
  revalidatePath("/");
}
