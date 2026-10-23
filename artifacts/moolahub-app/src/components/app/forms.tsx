import { useState } from "react";
import { useTranslation } from "react-i18next";
import { CheckCircle2, AlertCircle, Copy } from "lucide-react";
import { Button } from "@/components/ui";
import { formatMoney, cn } from "@/lib/utils";
import { parseAmountToCents, centsToAmountInput } from "@/lib/amount";

/** "$" shown before every amount input: users type dollars, never a token amount. */
function DollarPrefix() {
  return (
    <span dir="ltr" className="me-1 text-lg font-semibold text-muted-foreground" aria-hidden>
      $
    </span>
  );
}

/** Copy text to the clipboard with a brief confirmation. */
export function CopyButton({ value, className }: { value: string; className?: string }) {
  const { t } = useTranslation();
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
      {copied ? t("forms.copied") : t("forms.copy")}
    </button>
  );
}

/** Amount entry */
export function AmountForm({
  onSubmit,
  presets,
  submitLabel,
  variant = "primary",
  pending = false,
  error,
  ok,
}: {
  onSubmit: (amountCents: number) => void | Promise<void>;
  presets?: number[];
  submitLabel?: string;
  variant?: "primary" | "secondary" | "dark";
  pending?: boolean;
  error?: string | null;
  ok?: string | null;
}) {
  const { t } = useTranslation();
  const [value, setValue] = useState("");
  const [invalid, setInvalid] = useState(false);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!value) return;
    // String-based parse: "0.29" is 29¢, never 28¢ from float math.
    const cents = parseAmountToCents(value);
    if (cents === null || cents <= 0) {
      setInvalid(true);
      return;
    }
    setInvalid(false);
    void onSubmit(cents);
  };

  return (
    <form onSubmit={handleSubmit} className="space-y-3">
      <div dir="ltr" className="flex items-center rounded-2xl border border-border bg-card px-4 focus-within:ring-2 focus-within:ring-jade-500/40">
        <DollarPrefix />
        <input
          name="amount"
          inputMode="decimal"
          autoComplete="off"
          placeholder="0.00"
          value={value}
          onChange={(e) => {
            setValue(e.target.value);
            setInvalid(false);
          }}
          aria-invalid={invalid || undefined}
          className="h-12 w-full bg-transparent text-lg font-semibold text-foreground outline-none placeholder:text-muted-foreground"
          required
        />
      </div>

      {presets && (
        <div className="flex flex-wrap gap-2">
          {presets.map((p) => (
            <button
              key={p}
              type="button"
              onClick={() => {
                setValue(centsToAmountInput(p));
                setInvalid(false);
              }}
              className="cursor-pointer rounded-xl border border-border bg-card px-4 py-2 text-sm font-semibold text-foreground transition-[color,border-color,transform] duration-150 hover:border-jade-500/40 hover:text-jade-700 dark:hover:text-jade-300 active:scale-[0.98] focus-ring"
            >
              <span dir="ltr">+{formatMoney(p, { compact: true })}</span>
            </button>
          ))}
        </div>
      )}

      {(invalid || error) && (
        <p className="flex items-center gap-1.5 text-sm text-red-600" role="alert">
          <AlertCircle className="h-4 w-4" /> {invalid ? t("forms.invalidAmount") : error}
        </p>
      )}
      {ok && (
        <p className="flex items-center gap-1.5 text-sm text-jade-600 dark:text-jade-400">
          <CheckCircle2 className="h-4 w-4" /> {ok}
        </p>
      )}

      <Button type="submit" variant={variant} disabled={pending || !value} className="w-full">
        {pending ? t("forms.working") : (submitLabel ?? t("actions.confirm"))}
      </Button>
    </form>
  );
}

/**
 * Send to an outside account address. Technical details only: the default
 * views have no address entry (spec §1), so this renders behind the toggle.
 */
export function WithdrawForm({
  onSubmit,
  pending = false,
  error,
  ok
}: {
  onSubmit: (data: { destination: string, amountCents: number }) => void | Promise<void>;
  pending?: boolean;
  error?: string | null;
  ok?: string | null;
}) {
  const { t } = useTranslation();
  const [destination, setDestination] = useState("");
  const [amount, setAmount] = useState("");
  const [invalid, setInvalid] = useState(false);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!amount || !destination) return;
    const amountCents = parseAmountToCents(amount);
    if (amountCents === null || amountCents <= 0) {
      setInvalid(true);
      return;
    }
    setInvalid(false);
    void onSubmit({ destination: destination.trim(), amountCents });
  };

  return (
    <form onSubmit={handleSubmit} className="space-y-3">
      <input
        name="destination"
        type="text"
        autoComplete="off"
        spellCheck={false}
        placeholder={t("technical.send.recipientPlaceholder")}
        required
        value={destination}
        onChange={e => setDestination(e.target.value)}
        className="h-12 w-full rounded-2xl border border-border bg-card px-4 font-mono text-sm text-foreground outline-none focus:ring-2 focus:ring-jade-500/40"
      />
      <div dir="ltr" className="flex items-center rounded-2xl border border-border bg-card px-4 focus-within:ring-2 focus-within:ring-jade-500/40">
        <DollarPrefix />
        <input
          name="amount"
          inputMode="decimal"
          autoComplete="off"
          placeholder="0.00"
          required
          value={amount}
          onChange={(e) => {
            setAmount(e.target.value);
            setInvalid(false);
          }}
          aria-invalid={invalid || undefined}
          className="h-12 w-full bg-transparent text-lg font-semibold text-foreground outline-none placeholder:text-muted-foreground"
        />
      </div>
      <p className="text-xs text-muted-foreground">{t("legal.transfersOut")}</p>
      {(invalid || error) && (
        <p className="flex items-center gap-1.5 text-sm text-red-600" role="alert">
          <AlertCircle className="h-4 w-4" /> {invalid ? t("forms.invalidAmount") : error}
        </p>
      )}
      {ok && (
        <p className="flex items-center gap-1.5 text-sm text-jade-600 dark:text-jade-400">
          <CheckCircle2 className="h-4 w-4" /> {ok}
        </p>
      )}
      <Button type="submit" variant="secondary" disabled={pending || !amount || !destination} className="w-full">
        {pending ? t("forms.sending") : t("technical.send.submit")}
      </Button>
    </form>
  );
}

export function ActionButton({
  onClick,
  label,
  pendingLabel,
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
  const { t } = useTranslation();
  return (
    <div className={cn("inline-flex flex-col gap-2", className)}>
      <Button type="button" onClick={onClick} variant={variant} size={size} disabled={pending}>
        {pending ? (pendingLabel ?? t("forms.working")) : label}
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
  const { t } = useTranslation();
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
          {pending ? "…" : t("forms.invite")}
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
