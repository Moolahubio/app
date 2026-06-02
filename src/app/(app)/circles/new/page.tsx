"use client";

import { useActionState } from "react";
import { AlertCircle, ShieldCheck } from "lucide-react";
import { Card, Button } from "@/components/ui";
import { BackLink } from "@/components/app/bits";
import { createCircleAction, type ActionState } from "@/app/(app)/actions";

export default function NewCirclePage() {
  const [state, formAction, pending] = useActionState<ActionState, FormData>(createCircleAction, {});

  return (
    <div className="mx-auto max-w-xl space-y-6">
      <BackLink href="/circles" label="All circles" />
      <div>
        <h1 className="font-display text-3xl font-bold tracking-tight text-ink-900">
          Start a circle
        </h1>
        <p className="mt-2 text-ink-500">
          Set the contribution and schedule. You&apos;ll be first in the rotation — invite members
          once it&apos;s created.
        </p>
      </div>

      <Card className="p-6">
        <form action={formAction} className="space-y-5">
          <Field label="Circle name">
            <input
              name="name"
              type="text"
              placeholder="e.g. Family Savings"
              required
              className="h-12 w-full rounded-2xl border border-ink-900/10 bg-white px-4 text-ink-900 outline-none focus:ring-2 focus:ring-jade-500/40"
            />
          </Field>

          <Field label="Contribution per round (USDC)">
            <input
              name="contribution"
              inputMode="decimal"
              placeholder="50.00"
              required
              className="h-12 w-full rounded-2xl border border-ink-900/10 bg-white px-4 text-ink-900 outline-none focus:ring-2 focus:ring-jade-500/40"
            />
          </Field>

          <Field label="Frequency">
            <select
              name="frequency"
              defaultValue="monthly"
              className="h-12 w-full rounded-2xl border border-ink-900/10 bg-white px-4 text-ink-900 outline-none focus:ring-2 focus:ring-jade-500/40"
            >
              <option value="weekly">Weekly</option>
              <option value="biweekly">Every 2 weeks</option>
              <option value="monthly">Monthly</option>
            </select>
          </Field>

          {state.error && (
            <p className="flex items-center gap-1.5 text-sm text-red-600">
              <AlertCircle className="h-4 w-4" /> {state.error}
            </p>
          )}

          <div className="flex items-start gap-2 rounded-2xl bg-jade-50/60 p-4 text-xs text-ink-600">
            <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0 text-jade-600" />
            On mainnet, pooled funds run on an audited Soroban contract. New circles start on
            testnet until that audit clears.
          </div>

          <div className="flex gap-3 pt-1">
            <Button type="submit" size="lg" disabled={pending} className="flex-1">
              {pending ? "Creating…" : "Create circle"}
            </Button>
            <Button href="/circles" variant="secondary" size="lg">
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
