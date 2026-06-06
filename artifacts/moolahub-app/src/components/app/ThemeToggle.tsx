import { Sun, Moon, Monitor } from "lucide-react";
import { cn } from "@/lib/utils";
import { useTheme, type Theme } from "@/hooks/use-theme";

const OPTIONS: { value: Theme; label: string; icon: typeof Sun }[] = [
  { value: "light", label: "Light", icon: Sun },
  { value: "dark", label: "Dark", icon: Moon },
  { value: "system", label: "System", icon: Monitor },
];

/**
 * Compact 3-way theme switch (Light / Dark / System). The `variant="full"`
 * form shows labels for use in settings; the default icon-only form fits the
 * app header.
 */
export function ThemeToggle({
  variant = "icons",
  className,
}: {
  variant?: "icons" | "full";
  className?: string;
}) {
  const { theme, setTheme } = useTheme();

  return (
    <div
      role="radiogroup"
      aria-label="Theme"
      className={cn(
        "inline-flex items-center gap-1 rounded-xl border border-border bg-muted p-1",
        className,
      )}
    >
      {OPTIONS.map(({ value, label, icon: Icon }) => {
        const active = theme === value;
        return (
          <button
            key={value}
            type="button"
            role="radio"
            aria-checked={active}
            aria-label={label}
            title={label}
            onClick={() => setTheme(value)}
            className={cn(
              "inline-flex items-center justify-center gap-2 rounded-lg text-sm font-semibold transition-[color,background-color,box-shadow] duration-150 focus-ring active:scale-95",
              variant === "full" ? "flex-1 px-3 py-2" : "h-8 w-8",
              active
                ? "bg-card text-foreground shadow-sm"
                : "text-muted-foreground hover:text-foreground",
            )}
          >
            <Icon className="h-4 w-4" />
            {variant === "full" && <span>{label}</span>}
          </button>
        );
      })}
    </div>
  );
}
