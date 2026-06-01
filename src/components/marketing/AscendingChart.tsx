import { cn } from "@/lib/utils";

/**
 * The MoolaHub ascending-chart motif: a rising line that climbs through
 * nodes to a goal star — "start low, grow up". Used in the hero and
 * section accents.
 */
export function AscendingChart({ className }: { className?: string }) {
  const points = [
    [20, 230],
    [120, 250],
    [220, 175],
    [320, 200],
    [420, 110],
    [520, 140],
    [620, 40],
  ];
  const path = points.map((p, i) => `${i === 0 ? "M" : "L"} ${p[0]} ${p[1]}`).join(" ");
  const star = points[points.length - 1];

  return (
    <svg viewBox="0 0 660 280" className={cn("w-full", className)} fill="none" aria-hidden>
      <defs>
        <linearGradient id="lineGrad" x1="0" y1="280" x2="660" y2="0" gradientUnits="userSpaceOnUse">
          <stop stopColor="#0E9E6E" stopOpacity="0.5" />
          <stop offset="1" stopColor="#30C58A" />
        </linearGradient>
        <linearGradient id="fillGrad" x1="0" y1="0" x2="0" y2="280" gradientUnits="userSpaceOnUse">
          <stop stopColor="#0E9E6E" stopOpacity="0.25" />
          <stop offset="1" stopColor="#0E9E6E" stopOpacity="0" />
        </linearGradient>
      </defs>

      {/* area fill under the line */}
      <path d={`${path} L 620 280 L 20 280 Z`} fill="url(#fillGrad)" />

      {/* the ascending line, animated draw */}
      <path
        d={path}
        stroke="url(#lineGrad)"
        strokeWidth="4"
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeDasharray="1000"
        className="animate-draw-line"
      />

      {/* nodes */}
      {points.slice(0, -1).map((p, i) => (
        <circle key={i} cx={p[0]} cy={p[1]} r="6" fill="#0C1512" stroke="#30C58A" strokeWidth="3" />
      ))}

      {/* goal star at the peak */}
      <g transform={`translate(${star[0]} ${star[1]})`} className="animate-twinkle">
        <path
          d="M0 -26 L7 -7 L26 0 L7 7 L0 26 L-7 7 L-26 0 L-7 -7 Z"
          fill="#30C58A"
        />
      </g>
    </svg>
  );
}
