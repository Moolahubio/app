import { useState } from "react";
import { CheckCircle2, AlertCircle, Copy } from "lucide-react";
import { Button } from "@/components/ui";
import { formatMoney, cn } from "@/lib/utils";

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
        "inline-flex items-center gap-1.5 rounded-full bg-ink-900/[0.06] px-3 py-1.5 text-xs font-medium text-foreground transition-colors hover:bg-ink-900/[0.1] dark:bg-white/10 dark:hover:bg-white/15 focus-ring",
        className,
      )}
    >
      {copied ? <CheckCircle2 className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
      {copied ? "Copied" : "Copy"}
    </button>
  );
}

/** Amount entry */
export function AmountForm({
  onSubmit,
  presets,
  submitLabel = "Confirm",
  variant = "primary",
  pending = false,
  error,
  ok,
}: {
  onSubmit: (amountCents: number) => void;
  presets?: number[];
  submitLabel?: string;
  variant?: "primary" | "secondary" | "dark";
  pending?: boolean;
  error?: string | null;
  ok?: string | null;
}) {
  const [value, setValue] = useState("");

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!value) return;
    onSubmit(Math.floor(parseFloat(value) * 100));
  };

  return (
    <form onSubmit={handleSubmit} className="space-y-3">
      <div className="flex items-center rounded-2xl border border-border bg-card px-4 focus-within:ring-2 focus-within:ring-jade-500/40">
        <input
          name="amount"
          inputMode="decimal"
          autoComplete="off"
          placeholder="0.00"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          className="h-12 w-full bg-transparent text-lg font-semibold text-foreground outline-none placeholder:text-muted-foreground"
          required
        />
        <span className="font-mono text-xs uppercase tracking-[0.15em] text-muted-foreground">USDC</span>
      </div>

      {presets && (
        <div className="flex flex-wrap gap-2">
          {presets.map((p) => (
            <button
              key={p}
              type="button"
              onClick={() => setValue((p / 100).toString())}
              className="cursor-pointer rounded-xl border border-border bg-card px-4 py-2 text-sm font-semibold text-foreground transition-[color,border-color,transform] duration-150 hover:border-jade-500/40 hover:text-jade-700 dark:hover:text-jade-300 active:scale-[0.98] focus-ring"
            >
              +{formatMoney(p, { compact: true })}
            </button>
          ))}
        </div>
      )}

      {error && (
        <p className="flex items-center gap-1.5 text-sm text-red-600">
          <AlertCircle className="h-4 w-4" /> {error}
        </p>
      )}
      {ok && (
        <p className="flex items-center gap-1.5 text-sm text-jade-600 dark:text-jade-400">
          <CheckCircle2 className="h-4 w-4" /> {ok}
        </p>
      )}

      <Button type="submit" variant={variant} disabled={pending || !value} className="w-full">
        {pending ? "Working…" : submitLabel}
      </Button>
    </form>
  );
}

export function WithdrawForm({
  onSubmit,
  pending = false,
  error,
  ok
}: {
  onSubmit: (data: { destination: string, amountCents: number }) => void;
  pending?: boolean;
  error?: string | null;
  ok?: string | null;
}) {
  const [destination, setDestination] = useState("");
  const [amount, setAmount] = useState("");

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!amount || !destination) return;
    onSubmit({ destination, amountCents: Math.floor(parseFloat(amount) * 100) });
  };

  return (
    <form onSubmit={handleSubmit} className="space-y-3">
      <input
        name="destination"
        type="text"
        autoComplete="off"
        spellCheck={false}
        placeholder="Recipient Monad address (0x…)"
        required
        value={destination}
        onChange={e => setDestination(e.target.value)}
        className="h-12 w-full rounded-2xl border border-border bg-card px-4 font-mono text-sm text-foreground outline-none focus:ring-2 focus:ring-jade-500/40"
      />
      <div className="flex items-center rounded-2xl border border-border bg-card px-4 focus-within:ring-2 focus-within:ring-jade-500/40">
        <input
          name="amount"
          inputMode="decimal"
          autoComplete="off"
          placeholder="0.00"
          required
          value={amount}
          onChange={e => setAmount(e.target.value)}
          className="h-12 w-full bg-transparent text-lg font-semibold text-foreground outline-none placeholder:text-muted-foreground"
        />
        <span className="font-mono text-xs uppercase tracking-[0.15em] text-muted-foreground">USDC</span>
      </div>
      {error && (
        <p className="flex items-center gap-1.5 text-sm text-red-600">
          <AlertCircle className="h-4 w-4" /> {error}
        </p>
      )}
      {ok && (
        <p className="flex items-center gap-1.5 text-sm text-jade-600 dark:text-jade-400">
          <CheckCircle2 className="h-4 w-4" /> {ok}
        </p>
      )}
      <Button type="submit" variant="secondary" disabled={pending || !amount || !destination} className="w-full">
        {pending ? "Sending…" : "Withdraw USDC"}
      </Button>
    </form>
  );
}

export function ActionButton({
  onClick,
  label,
  pendingLabel = "Working…",
  variant = "primary",
  size = "md",
  className,
  pending = false,
  error
}: {
  onClick: () => void;
  label: string;
  pendingLabel?: string;
  variant?: "primary" | "secondary" | "dark";
  size?: "sm" | "md" | "lg";
  className?: string;
  pending?: boolean;
  error?: string | null;
}) {
  return (
    <div className={cn("inline-flex flex-col gap-2", className)}>
      <Button type="button" onClick={onClick} variant={variant} size={size} disabled={pending}>
        {pending ? pendingLabel : label}
      </Button>
      {error && (
        <span className="flex items-center gap-1.5 text-sm text-red-600">
          <AlertCircle className="h-4 w-4" /> {error}
        </span>
      )}
    </div>
  );
}

export function InviteForm({ onSubmit, pending, ok, error }: { onSubmit: (email: string) => void, pending?: boolean, ok?: string | null, error?: string | null }) {
  const [email, setEmail] = useState("");
  return (
    <form onSubmit={(e) => { e.preventDefault(); if(email) onSubmit(email); }} className="space-y-2">
      <div className="flex gap-2">
        <input
          name="email"
          type="email"
          placeholder="friend@email.com"
          required
          value={email}
          onChange={e => setEmail(e.target.value)}
          className="h-11 w-full rounded-2xl border border-border bg-card px-4 text-sm text-foreground outline-none focus:ring-2 focus:ring-jade-500/40"
        />
        <Button type="submit" disabled={pending || !email} size="sm">
          {pending ? "…" : "Invite"}
        </Button>
      </div>
      {error && (
        <p className="flex items-center gap-1.5 text-sm text-red-600">
          <AlertCircle className="h-4 w-4" /> {error}
        </p>
      )}
      {ok && (
        <p className="flex items-center gap-1.5 text-sm text-jade-600 dark:text-jade-400">
          <CheckCircle2 className="h-4 w-4" /> {ok}
        </p>
      )}
    </form>
  );
}
