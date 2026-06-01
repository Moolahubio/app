import { cn } from "@/lib/utils";

type Tone = "ink" | "light";

/**
 * MoolaHub mark — an open savings ring, an ascending "M" (a rising chart),
 * and a north-east goal star. Recreated as SVG so it stays crisp at any size
 * and themes cleanly across light (jade) and dark (white + jade star) surfaces.
 */
export function MoolaMark({
  className,
  tone = "ink",
  title = "MoolaHub",
}: {
  className?: string;
  tone?: Tone;
  title?: string;
}) {
  const ringColor = tone === "light" ? "#FFFFFF" : "#0E9E6E";
  const star = "#0E9E6E";
  return (
    <svg
      viewBox="0 0 100 100"
      className={className}
      role="img"
      aria-label={title}
      fill="none"
    >
      {/* Open savings ring (two arcs, rounded caps) */}
      <circle
        cx="50"
        cy="50"
        r="38"
        stroke={ringColor}
        strokeWidth="8.5"
        strokeLinecap="round"
        strokeDasharray="150 16 60 12"
        transform="rotate(60 50 50)"
      />
      {/* Ascending M / rising chart */}
      <path
        d="M30 65 L41 49 L50 57 L67 33"
        stroke={ringColor}
        strokeWidth="8.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      {/* Goal star (north-east) */}
      <path
        d="M74 11 L77.6 20.4 L87 24 L77.6 27.6 L74 37 L70.4 27.6 L61 24 L70.4 20.4 Z"
        fill={star}
      />
    </svg>
  );
}

/**
 * Full horizontal lockup: mark + "MoolaHub" wordmark
 * ("Moola" in the foreground tone, "Hub" in jade).
 */
export function Logo({
  className,
  tone = "ink",
  showWordmark = true,
  markClassName,
}: {
  className?: string;
  tone?: Tone;
  showWordmark?: boolean;
  markClassName?: string;
}) {
  return (
    <span className={cn("inline-flex items-center gap-2.5", className)}>
      <MoolaMark tone={tone} className={cn("h-8 w-8 shrink-0", markClassName)} />
      {showWordmark && (
        <span
          className={cn(
            "font-display text-2xl font-extrabold tracking-tight",
            tone === "light" ? "text-white" : "text-ink-900",
          )}
        >
          Moola<span className="text-jade-500">Hub</span>
        </span>
      )}
    </span>
  );
}
