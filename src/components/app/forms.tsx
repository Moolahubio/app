"use client";

import { useActionState, useState } from "react";
import { CheckCircle2, AlertCircle, Copy } from "lucide-react";
import { Button } from "@/components/ui";
import { formatMoney, cn } from "@/lib/utils";
import { inviteMemberAction, withdrawAction, type ActionState } from "@/app/(app)/actions";

type Action = (prev: ActionState, fd: FormData) => Promise<ActionState>;

/** Withdraw USDC to an external Base address. */
export function WithdrawForm() {
  const [state, formAction, pending] = useActionState(withdrawAction, {});
  return (
    <form action={formAction} className="space-y-3">
      <input
        name="destination"
        type="text"
        autoComplete="off"
        spellCheck={false}
        placeholder="Recipient Base address (0x…)"
        required
        className="h-12 w-full rounded-2xl border border-ink-900/10 bg-white px-4 font-mono text-sm text-ink-900 outline-none focus:ring-2 focus:ring-jade-500/40"
      />
      <div className="flex items-center rounded-2xl border border-ink-900/10 bg-white px-4 focus-within:ring-2 focus-within:ring-jade-500/40">
        <input
          name="amount"
          inputMode="decimal"
          autoComplete="off"
          placeholder="0.00"
          required
          className="h-12 w-full bg-transparent text-lg font-semibold text-ink-900 outline-none placeholder:text-ink-300"
        />
        <span className="font-mono text-xs uppercase tracking-[0.15em] text-ink-400">USDC</span>
      </div>
      {state.error && (
        <p className="flex items-center gap-1.5 text-sm text-red-600">
          <AlertCircle className="h-4 w-4" /> {state.error}
        </p>
      )}
      {state.ok && (
        <p className="flex items-center gap-1.5 text-sm text-jade-600">
          <CheckCircle2 className="h-4 w-4" /> Withdrawal submitted.
        </p>
      )}
      <Button type="submit" variant="secondary" disabled={pending} className="w-full">
        {pending ? "Sending…" : "Withdraw USDC"}
      </Button>
    </form>
  );
}

/** Invite a member to a forming circle by email. */
export function InviteForm({ circleId }: { circleId: string }) {
  const [state, formAction, pending] = useActionState(inviteMemberAction, {});
  return (
    <form action={formAction} className="space-y-2">
      <input type="hidden" name="circleId" value={circleId} />
      <div className="flex gap-2">
        <input
          name="email"
          type="email"
          placeholder="friend@email.com"
          required
          className="h-11 w-full rounded-2xl border border-ink-900/10 bg-white px-4 text-sm text-ink-900 outline-none focus:ring-2 focus:ring-jade-500/40"
        />
        <Button type="submit" disabled={pending} size="sm">
          {pending ? "…" : "Invite"}
        </Button>
      </div>
      {state.error && (
        <p className="flex items-center gap-1.5 text-sm text-red-600">
          <AlertCircle className="h-4 w-4" /> {state.error}
        </p>
      )}
      {state.ok && (
        <p className="flex items-center gap-1.5 text-sm text-jade-600">
          <CheckCircle2 className="h-4 w-4" /> Invitation sent.
        </p>
      )}
    </form>
  );
}

/** Copy text to the clipboard with a brief confirmation. */
export function CopyButton({ value, className }: { value: string; className?: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      type="button"
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(value);
          setCopied(true);
          setTimeout(() => setCopied(false), 1500);
        } catch {
          /* clipboard unavailable */
        }
      }}
      className={cn(
        "inline-flex items-center gap-1.5 rounded-full bg-white/10 px-3 py-1.5 text-xs font-medium text-white transition-colors hover:bg-white/15 focus-ring",
        className,
      )}
    >
      {copied ? <CheckCircle2 className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
      {copied ? "Copied" : "Copy"}
    </button>
  );
}

/** Amount entry bound to a server action (deposit, withdraw, allocate, …). */
export function AmountForm({
  action,
  hidden,
  presets,
  submitLabel = "Confirm",
  variant = "primary",
}: {
  action: Action;
  hidden?: Record<string, string>;
  presets?: number[];
  submitLabel?: string;
  variant?: "primary" | "secondary" | "dark";
}) {
  const [state, formAction, pending] = useActionState(action, {});
  const [value, setValue] = useState("");

  return (
    <form action={formAction} className="space-y-3">
      {hidden &&
        Object.entries(hidden).map(([k, v]) => <input key={k} type="hidden" name={k} value={v} />)}

      <div className="flex items-center rounded-2xl border border-ink-900/10 bg-white px-4 focus-within:ring-2 focus-within:ring-jade-500/40">
        <input
          name="amount"
          inputMode="decimal"
          autoComplete="off"
          placeholder="0.00"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          className="h-12 w-full bg-transparent text-lg font-semibold text-ink-900 outline-none placeholder:text-ink-300"
          required
        />
        <span className="font-mono text-xs uppercase tracking-[0.15em] text-ink-400">USDC</span>
      </div>

      {presets && (
        <div className="flex flex-wrap gap-2">
          {presets.map((p) => (
            <button
              key={p}
              type="button"
              onClick={() => setValue((p / 100).toString())}
              className="rounded-full border border-ink-900/10 bg-white px-4 py-2 text-sm font-semibold text-ink-700 transition-colors hover:border-jade-500/40 hover:text-jade-700 focus-ring"
            >
              +{formatMoney(p, { compact: true })}
            </button>
          ))}
        </div>
      )}

      {state.error && (
        <p className="flex items-center gap-1.5 text-sm text-red-600">
          <AlertCircle className="h-4 w-4" /> {state.error}
        </p>
      )}
      {state.ok && (
        <p className="flex items-center gap-1.5 text-sm text-jade-600">
          <CheckCircle2 className="h-4 w-4" /> Done — your balance is updated.
        </p>
      )}

      <Button type="submit" variant={variant} disabled={pending} className="w-full">
        {pending ? "Working…" : submitLabel}
      </Button>
    </form>
  );
}

/** A single-action button bound to a server action (contribute, etc.). */
export function ActionButton({
  action,
  hidden,
  label,
  pendingLabel = "Working…",
  variant = "primary",
  size = "md",
  className,
}: {
  action: Action;
  hidden?: Record<string, string>;
  label: string;
  pendingLabel?: string;
  variant?: "primary" | "secondary" | "dark";
  size?: "sm" | "md" | "lg";
  className?: string;
}) {
  const [state, formAction, pending] = useActionState(action, {});
  return (
    <form action={formAction} className={cn("inline-flex flex-col gap-2", className)}>
      {hidden &&
        Object.entries(hidden).map(([k, v]) => <input key={k} type="hidden" name={k} value={v} />)}
      <Button type="submit" variant={variant} size={size} disabled={pending}>
        {pending ? pendingLabel : label}
      </Button>
      {state.error && (
        <span className="flex items-center gap-1.5 text-sm text-red-600">
          <AlertCircle className="h-4 w-4" /> {state.error}
        </span>
      )}
    </form>
  );
}
