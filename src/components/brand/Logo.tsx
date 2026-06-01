import { cn } from "@/lib/utils";

type Tone = "ink" | "light";

/**
 * MoolaHub mark — the exact brand geometry from the official assets:
 * an open savings ring (two arcs), an ascending "M" / rising chart, and a
 * north-east goal star. Pure SVG so it stays crisp and themes cleanly.
 *
 *  - tone="ink"  (light surfaces): jade ring + M, jade star
 *  - tone="light" (dark surfaces): white ring + M, jade star (matches the app icon)
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
  const ring = tone === "light" ? "#FFFFFF" : "#0E9E6E";
  const star = "#0E9E6E";
  return (
    <svg
      viewBox="30 30 150 150"
      className={className}
      role="img"
      aria-label={title}
      fill="none"
    >
      {/* open savings ring — two arcs */}
      <path
        d="M 56.786 173.384 A 72 72 0 0 1 122.972 46.243"
        stroke={ring}
        strokeWidth="12"
        strokeLinecap="round"
      />
      <path
        d="M 154.249 70.679 A 72 72 0 0 1 135.214 173.384"
        stroke={ring}
        strokeWidth="12"
        strokeLinecap="round"
      />
      {/* ascending M / rising chart */}
      <path
        d="M 52 151 L 78 113 L 99 133 L 123 82 L 142 116"
        stroke={ring}
        strokeWidth="12"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      {/* goal star (north-east) */}
      <path
        d="M 156.328 56.263 L 144.174 60.110 L 140.328 72.263 L 136.481 60.110 L 124.328 56.263 L 136.481 52.417 L 140.328 40.263 L 144.174 52.417 Z"
        fill={star}
      />
    </svg>
  );
}

/**
 * Full horizontal lockup — the official "MoolaHub" wordmark SVG.
 * Uses the dark-variant artwork (white "Moola") on dark surfaces.
 */
export function Logo({
  className,
  tone = "ink",
  markClassName,
}: {
  className?: string;
  tone?: Tone;
  /** kept for API compatibility with prior callers */
  markClassName?: string;
  showWordmark?: boolean;
}) {
  const src =
    tone === "light"
      ? "/brand/moolahub_logo_horizontal_dark.svg"
      : "/brand/moolahub_logo_horizontal.svg";
  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src={src}
      alt="MoolaHub"
      className={cn("w-auto shrink-0 object-contain", markClassName ?? "h-9", className)}
    />
  );
}
