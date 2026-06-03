import { cn } from "@/lib/utils";

export type SegmentOption<T extends string> = {
  value: T;
  label: string;
};

export function SegmentedControl<T extends string>({
  options,
  value,
  onChange,
  className,
  "aria-label": ariaLabel = "Options",
}: {
  options: SegmentOption<T>[];
  value: T;
  onChange: (value: T) => void;
  className?: string;
  "aria-label"?: string;
}) {
  return (
    <div
      role="tablist"
      aria-label={ariaLabel}
      className={cn(
        "inline-flex w-full rounded-xl border border-ink-900/10 bg-ink-900/[0.04] p-1",
        className,
      )}
    >
      {options.map((opt) => {
        const active = opt.value === value;
        return (
          <button
            key={opt.value}
            type="button"
            role="tab"
            aria-selected={active}
            onClick={() => onChange(opt.value)}
            className={cn(
              "relative flex-1 rounded-lg px-4 py-2.5 text-sm font-semibold transition-[color,background-color,box-shadow] duration-200 ease-out",
              "focus-ring active:scale-[0.99]",
              active
                ? "bg-white text-ink-900 shadow-[0_1px_2px_rgba(12,21,18,0.06)]"
                : "text-ink-500 hover:text-ink-800",
            )}
          >
            {opt.label}
          </button>
        );
      })}
    </div>
  );
}
