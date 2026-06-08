type MarkTone = "ink" | "light";

/** MoolaHub logo mark — open savings ring + ascending chart + goal star. */
export function MoolaMark({ className, tone = "ink" }: { className?: string; tone?: MarkTone }) {
  const ring = tone === "light" ? "#FFFFFF" : "#0E9E6E";
  const star = "#0E9E6E";
  return (
    <svg viewBox="30 30 150 150" className={className} role="img" aria-label="MoolaHub" fill="none">
      <path d="M 56.786 173.384 A 72 72 0 0 1 122.972 46.243" stroke={ring} strokeWidth="12" strokeLinecap="round" />
      <path d="M 154.249 70.679 A 72 72 0 0 1 135.214 173.384" stroke={ring} strokeWidth="12" strokeLinecap="round" />
      <path d="M 52 151 L 78 113 L 99 133 L 123 82 L 142 116" stroke={ring} strokeWidth="12" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M 156.328 56.263 L 144.174 60.110 L 140.328 72.263 L 136.481 60.110 L 124.328 56.263 L 136.481 52.417 L 140.328 40.263 L 144.174 52.417 Z" fill={star} />
    </svg>
  );
}

/** MoolaHub wordmark: mark + "MoolaHub" text. tone controls text color. */
export function Wordmark({ tone = "ink", className }: { tone?: MarkTone; className?: string }) {
  const text = tone === "light" ? "#FFFFFF" : "#0C1512";
  return (
    <div className={`flex items-center gap-2 ${className ?? ""}`}>
      <MoolaMark tone={tone} className="h-8 w-8" />
      <span className="mh-display text-xl font-extrabold tracking-tight" style={{ color: text }}>
        Moola<span style={{ color: "#0E9E6E" }}>Hub</span>
      </span>
    </div>
  );
}

/** Animated ascending savings chart — the signature MoolaHub growth motif. */
export function AscendingChart({ className }: { className?: string }) {
  const points: [number, number][] = [
    [20, 230], [120, 250], [220, 175], [320, 200], [420, 110], [520, 140], [620, 40],
  ];
  const path = points.map((p, i) => `${i === 0 ? "M" : "L"} ${p[0]} ${p[1]}`).join(" ");
  const star = points[points.length - 1];
  return (
    <svg viewBox="0 0 660 280" className={`w-full ${className ?? ""}`} fill="none" aria-hidden>
      <defs>
        <linearGradient id="mhLineGrad" x1="0" y1="280" x2="660" y2="0" gradientUnits="userSpaceOnUse">
          <stop stopColor="#0E9E6E" stopOpacity="0.5" />
          <stop offset="1" stopColor="#30C58A" />
        </linearGradient>
        <linearGradient id="mhFillGrad" x1="0" y1="0" x2="0" y2="280" gradientUnits="userSpaceOnUse">
          <stop stopColor="#0E9E6E" stopOpacity="0.25" />
          <stop offset="1" stopColor="#0E9E6E" stopOpacity="0" />
        </linearGradient>
      </defs>
      <path d={`${path} L 620 280 L 20 280 Z`} fill="url(#mhFillGrad)" />
      <path d={path} stroke="url(#mhLineGrad)" strokeWidth="4" strokeLinecap="round" strokeLinejoin="round" strokeDasharray="1000" className="mh-animate-draw" />
      {points.slice(0, -1).map((p, i) => (
        <circle key={i} cx={p[0]} cy={p[1]} r="6" fill="#0C1512" stroke="#30C58A" strokeWidth="3" />
      ))}
      <g transform={`translate(${star[0]} ${star[1]})`} className="mh-animate-twinkle">
        <path d="M0 -26 L7 -7 L26 0 L7 7 L0 26 L-7 7 L-26 0 L-7 -7 Z" fill="#30C58A" />
      </g>
    </svg>
  );
}

/** MoolaHub brand palette — share exact values across variants. */
export const MH = {
  jade50: "#ECFBF4", jade100: "#CFF5E3", jade200: "#A1EAC9", jade300: "#67DBAB",
  jade400: "#30C58A", jade500: "#0E9E6E", jade600: "#0B8A60", jade700: "#0A6E4E",
  ink950: "#070D0B", ink900: "#0C1512", ink850: "#0F1814", ink800: "#14201B",
  ink700: "#1B2A24", ink600: "#26392F", ink500: "#3A5046", ink400: "#5C7468",
  paper: "#FFFFFF", mist: "#F5F8F6",
} as const;
