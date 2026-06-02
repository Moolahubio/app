"use server";

import { z } from "zod";
import { redirect } from "next/navigation";
import { db } from "@/lib/db";
import { hashPassword, verifyPassword, createSession } from "@/lib/server/auth";
import { createWalletForUser } from "@/lib/server/wallet";

export type AuthState = { error?: string };

const credentials = z.object({
  email: z.string().email("Enter a valid email address."),
  password: z.string().min(8, "Password must be at least 8 characters."),
});

export async function loginAction(_prev: AuthState, formData: FormData): Promise<AuthState> {
  const parsed = credentials.safeParse({
    email: String(formData.get("email") ?? "").trim().toLowerCase(),
    password: String(formData.get("password") ?? ""),
  });
  if (!parsed.success) return { error: parsed.error.issues[0].message };

  const user = await db.user.findUnique({ where: { email: parsed.data.email } });
  if (!user || !user.passwordHash) {
    return { error: "Incorrect email or password." };
  }
  if (!(await verifyPassword(parsed.data.password, user.passwordHash))) {
    return { error: "Incorrect email or password." };
  }
  await createSession(user.id);
  redirect("/");
}

export async function signupAction(_prev: AuthState, formData: FormData): Promise<AuthState> {
  const name = String(formData.get("name") ?? "").trim();
  const parsed = credentials.safeParse({
    email: String(formData.get("email") ?? "").trim().toLowerCase(),
    password: String(formData.get("password") ?? ""),
  });
  if (!name) return { error: "Please enter your name." };
  if (!parsed.success) return { error: parsed.error.issues[0].message };

  const existing = await db.user.findUnique({ where: { email: parsed.data.email } });
  if (existing) return { error: "An account with that email already exists." };

  const user = await db.user.create({
    data: {
      name,
      email: parsed.data.email,
      passwordHash: await hashPassword(parsed.data.password),
      kycStatus: "unstarted",
    },
  });
  await createWalletForUser(user.id);
  await createSession(user.id);
  redirect("/");
}
