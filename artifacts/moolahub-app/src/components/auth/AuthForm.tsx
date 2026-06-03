import { useState } from "react";
import { Mail, Lock, User, ArrowRight, AlertCircle } from "lucide-react";
import { Button } from "@/components/ui";
import { SegmentedControl } from "@/components/app/SegmentedControl";
import { useLogin, useRegister, getGetMeQueryKey } from "@workspace/api-client-react";
import { apiErrorMessage } from "@/lib/utils";
import { useLocation } from "wouter";
import { useQueryClient } from "@tanstack/react-query";

export function AuthForm() {
  const [mode, setMode] = useState<"signup" | "login">("signup");
  const [, setLocation] = useLocation();
  const queryClient = useQueryClient();

  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");

  const loginMutation = useLogin();
  const registerMutation = useRegister();

  const pending = loginMutation.isPending || registerMutation.isPending;
  const error = apiErrorMessage(loginMutation.error) || apiErrorMessage(registerMutation.error);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (mode === "signup") {
      registerMutation.mutate(
        { data: { name, email, password } },
        {
          onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() });
            setLocation("/");
          }
        }
      );
    } else {
      loginMutation.mutate(
        { data: { email, password } },
        {
          onSuccess: () => {
            queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() });
            setLocation("/");
          }
        }
      );
    }
  };

  return (
    <div>
      <SegmentedControl
        aria-label="Sign up or sign in"
        options={[
          { value: "signup", label: "Create account" },
          { value: "login", label: "Sign in" },
        ]}
        value={mode}
        onChange={(v) => setMode(v as "signup" | "login")}
      />

      <h2 className="mt-8 font-display text-2xl font-bold tracking-tight text-ink-900">
        {mode === "signup" ? "Start saving today" : "Welcome back"}
      </h2>
      <p className="mt-2 text-sm leading-relaxed text-ink-500">
        {mode === "signup"
          ? "Personal goals and trusted circles — one wallet on Base."
          : "Sign in to your MoolaHub wallet."}
      </p>

      <form onSubmit={handleSubmit} className="mt-6 space-y-3">
        {mode === "signup" && (
          <Field icon={<User className="h-5 w-5 text-ink-400" />}>
            <input
              name="name"
              type="text"
              placeholder="Full name"
              autoComplete="name"
              value={name}
              onChange={e => setName(e.target.value)}
              className="h-11 w-full bg-transparent text-ink-900 outline-none placeholder:text-ink-400"
              required={mode === "signup"}
            />
          </Field>
        )}
        <Field icon={<Mail className="h-5 w-5 text-ink-400" />}>
          <input
            name="email"
            type="email"
            placeholder="you@example.com"
            autoComplete="email"
            value={email}
            onChange={e => setEmail(e.target.value)}
            className="h-11 w-full bg-transparent text-ink-900 outline-none placeholder:text-ink-400"
            required
          />
        </Field>
        <Field icon={<Lock className="h-5 w-5 text-ink-400" />}>
          <input
            name="password"
            type="password"
            placeholder="Password (min 8 characters)"
            autoComplete={mode === "signup" ? "new-password" : "current-password"}
            value={password}
            onChange={e => setPassword(e.target.value)}
            className="h-11 w-full bg-transparent text-ink-900 outline-none placeholder:text-ink-400"
            required
          />
        </Field>

        {error && (
          <p className="flex items-center gap-1.5 text-sm text-red-600" role="alert">
            <AlertCircle className="h-4 w-4 shrink-0" /> {error}
          </p>
        )}

        <Button type="submit" size="lg" className="w-full" disabled={pending}>
          {pending ? "Please wait…" : mode === "signup" ? "Create account" : "Sign in"}
          {!pending && <ArrowRight className="h-4 w-4" />}
        </Button>
      </form>
    </div>
  );
}

function Field({ icon, children }: { icon: React.ReactNode; children: React.ReactNode }) {
  return (
    <label className="flex items-center gap-2 rounded-xl border border-ink-900/10 bg-white px-4 transition-[border-color,box-shadow] duration-150 focus-within:border-jade-500/40 focus-within:ring-2 focus-within:ring-jade-500/20">
      {icon}
      {children}
    </label>
  );
}
