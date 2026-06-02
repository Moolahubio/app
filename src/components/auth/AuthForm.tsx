"use client";

import { useActionState, useState } from "react";
import { Mail, Lock, User, ArrowRight, AlertCircle } from "lucide-react";
import { Button } from "@/components/ui";
import { loginAction, signupAction, type AuthState } from "@/app/login/actions";

export function AuthForm() {
  const [mode, setMode] = useState<"signup" | "login">("signup");
  const action = mode === "signup" ? signupAction : loginAction;
  const [state, formAction, pending] = useActionState<AuthState, FormData>(action, {});

  return (
    <div>
      <h2 className="font-display text-3xl font-bold tracking-tight text-ink-900">
        {mode === "signup" ? "Create your account" : "Welcome back"}
      </h2>
      <p className="mt-2 text-ink-500">
        {mode === "signup"
          ? "Start saving toward what matters — on your own and with your community."
          : "Sign in to your MoolaHub wallet."}
      </p>

      <form action={formAction} className="mt-8 space-y-3">
        {mode === "signup" && (
          <Field icon={<User className="h-5 w-5 text-ink-400" />}>
            <input
              name="name"
              type="text"
              placeholder="Full name"
              autoComplete="name"
              className="h-12 w-full bg-transparent text-ink-900 outline-none placeholder:text-ink-400"
              required
            />
          </Field>
        )}
        <Field icon={<Mail className="h-5 w-5 text-ink-400" />}>
          <input
            name="email"
            type="email"
            placeholder="you@example.com"
            autoComplete="email"
            className="h-12 w-full bg-transparent text-ink-900 outline-none placeholder:text-ink-400"
            required
          />
        </Field>
        <Field icon={<Lock className="h-5 w-5 text-ink-400" />}>
          <input
            name="password"
            type="password"
            placeholder="Password (min 8 characters)"
            autoComplete={mode === "signup" ? "new-password" : "current-password"}
            className="h-12 w-full bg-transparent text-ink-900 outline-none placeholder:text-ink-400"
            required
          />
        </Field>

        {state.error && (
          <p className="flex items-center gap-1.5 text-sm text-red-600">
            <AlertCircle className="h-4 w-4" /> {state.error}
          </p>
        )}

        <Button type="submit" size="lg" className="w-full" disabled={pending}>
          {pending ? "Please wait…" : mode === "signup" ? "Create account" : "Sign in"}
          {!pending && <ArrowRight className="h-4 w-4" />}
        </Button>
      </form>

      <p className="mt-6 text-center text-sm text-ink-500">
        {mode === "signup" ? "Already have an account?" : "New to MoolaHub?"}{" "}
        <button
          type="button"
          onClick={() => setMode(mode === "signup" ? "login" : "signup")}
          className="font-semibold text-jade-600 hover:text-jade-700"
        >
          {mode === "signup" ? "Sign in" : "Create an account"}
        </button>
      </p>

      <p className="mt-4 rounded-2xl bg-mist px-4 py-3 text-center text-xs text-ink-500">
        Try the demo: <span className="font-semibold text-ink-700">ama@moolahub.io</span> /{" "}
        <span className="font-semibold text-ink-700">moolahub</span>
      </p>
    </div>
  );
}

function Field({ icon, children }: { icon: React.ReactNode; children: React.ReactNode }) {
  return (
    <label className="flex items-center gap-2 rounded-2xl border border-ink-900/10 bg-white px-4 focus-within:ring-2 focus-within:ring-jade-500/40">
      {icon}
      {children}
    </label>
  );
}
