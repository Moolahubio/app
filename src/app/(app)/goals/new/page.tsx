"use client";

import { useActionState, useState } from "react";
import { AlertCircle } from "lucide-react";
import { Card, Button } from "@/components/ui";
import { BackLink } from "@/components/app/bits";
import { createGoalAction, type ActionState } from "@/app/(app)/actions";

const EMOJIS = ["🎯", "🏠", "💻", "🛟", "✈️", "🚗", "🎓", "👶", "💍", "🏥"];

export default function NewGoalPage() {
  const [state, formAction, pending] = useActionState<ActionState, FormData>(createGoalAction, {});
  const [emoji, setEmoji] = useState("🎯");

  return (
    <div className="mx-auto max-w-xl space-y-6">
      <BackLink href="/goals" label="All goals" />
      <div>
        <h1 className="font-display text-3xl font-bold tracking-tight text-ink-900">
          Create a goal
        </h1>
        <p className="mt-2 text-ink-500">
          Set a target and an optional weekly auto-save. Funds stay in your wallet — a goal just
          earmarks them.
        </p>
      </div>

      <Card className="p-6">
        <form action={formAction} className="space-y-5">
          <input type="hidden" name="emoji" value={emoji} />

          <div>
            <label className="text-sm font-medium text-ink-700">Icon</label>
            <div className="mt-2 flex flex-wrap gap-2">
              {EMOJIS.map((e) => (
                <button
                  key={e}
                  type="button"
                  onClick={() => setEmoji(e)}
                  className={`flex h-10 w-10 items-center justify-center rounded-xl text-xl transition-all ${
                    emoji === e ? "bg-jade-50 ring-2 ring-jade-500" : "bg-mist hover:bg-ink-900/[0.06]"
                  }`}
                >
                  {e}
                </button>
              ))}
            </div>
          </div>

          <Field label="Goal name">
            <input
              name="name"
              type="text"
              placeholder="e.g. Rent buffer"
              required
              className="h-12 w-full rounded-2xl border border-ink-900/10 bg-white px-4 text-ink-900 outline-none focus:ring-2 focus:ring-jade-500/40"
            />
          </Field>

          <div className="grid gap-4 sm:grid-cols-2">
            <Field label="Target amount (USDC)">
              <input
                name="target"
                inputMode="decimal"
                placeholder="2000.00"
                required
                className="h-12 w-full rounded-2xl border border-ink-900/10 bg-white px-4 text-ink-900 outline-none focus:ring-2 focus:ring-jade-500/40"
              />
            </Field>
            <Field label="Target date">
              <input
                name="deadline"
                type="date"
                className="h-12 w-full rounded-2xl border border-ink-900/10 bg-white px-4 text-ink-900 outline-none focus:ring-2 focus:ring-jade-500/40"
              />
            </Field>
          </div>

          <Field label="Weekly auto-save (USDC, optional)">
            <input
              name="autoSave"
              inputMode="decimal"
              placeholder="50.00"
              className="h-12 w-full rounded-2xl border border-ink-900/10 bg-white px-4 text-ink-900 outline-none focus:ring-2 focus:ring-jade-500/40"
            />
          </Field>

          {state.error && (
            <p className="flex items-center gap-1.5 text-sm text-red-600">
              <AlertCircle className="h-4 w-4" /> {state.error}
            </p>
          )}

          <div className="flex gap-3 pt-2">
            <Button type="submit" size="lg" disabled={pending} className="flex-1">
              {pending ? "Creating…" : "Create goal"}
            </Button>
            <Button href="/goals" variant="secondary" size="lg">
              Cancel
            </Button>
          </div>
        </form>
      </Card>
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="block">
      <span className="text-sm font-medium text-ink-700">{label}</span>
      <div className="mt-1.5">{children}</div>
    </label>
  );
}
