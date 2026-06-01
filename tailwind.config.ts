import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./src/**/*.{ts,tsx,mdx}"],
  theme: {
    extend: {
      colors: {
        // MoolaHub brand palette — Jade / Ink / Paper
        jade: {
          50: "#ECFBF4",
          100: "#CFF5E3",
          200: "#A1EAC9",
          300: "#67DBAB",
          400: "#30C58A",
          500: "#0E9E6E", // brand primary
          600: "#0B8A60",
          700: "#0A6E4E",
          800: "#0B563F",
          900: "#0A3F2F",
        },
        ink: {
          DEFAULT: "#0C1512",
          950: "#070D0B",
          900: "#0C1512", // brand ink
          850: "#0F1814",
          800: "#14201B",
          700: "#1B2A24",
          600: "#26392F",
          500: "#3A5046",
          400: "#5C7468",
        },
        paper: "#FFFFFF",
        mist: "#F5F8F6",
      },
      fontFamily: {
        sans: ["var(--font-sans)", "ui-sans-serif", "system-ui", "sans-serif"],
        display: ["var(--font-display)", "var(--font-sans)", "sans-serif"],
        mono: ["var(--font-mono)", "ui-monospace", "SFMono-Regular", "monospace"],
      },
      borderRadius: {
        "4xl": "2rem",
      },
      boxShadow: {
        card: "0 1px 2px rgba(12, 21, 18, 0.04), 0 8px 24px -12px rgba(12, 21, 18, 0.12)",
        "card-hover": "0 2px 4px rgba(12, 21, 18, 0.06), 0 16px 40px -16px rgba(12, 21, 18, 0.18)",
        glow: "0 0 0 1px rgba(14,158,110,0.2), 0 12px 40px -12px rgba(14,158,110,0.45)",
      },
      backgroundImage: {
        "grid-dark":
          "linear-gradient(rgba(255,255,255,0.04) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.04) 1px, transparent 1px)",
        "grid-light":
          "linear-gradient(rgba(12,21,18,0.045) 1px, transparent 1px), linear-gradient(90deg, rgba(12,21,18,0.045) 1px, transparent 1px)",
      },
      keyframes: {
        "fade-up": {
          "0%": { opacity: "0", transform: "translateY(12px)" },
          "100%": { opacity: "1", transform: "translateY(0)" },
        },
        "draw-line": {
          "0%": { strokeDashoffset: "1000" },
          "100%": { strokeDashoffset: "0" },
        },
        "pulse-soft": {
          "0%, 100%": { opacity: "1" },
          "50%": { opacity: "0.55" },
        },
        twinkle: {
          "0%, 100%": { opacity: "0.4", transform: "scale(0.9)" },
          "50%": { opacity: "1", transform: "scale(1.1)" },
        },
      },
      animation: {
        "fade-up": "fade-up 0.6s ease-out both",
        "draw-line": "draw-line 2.4s ease-out forwards",
        "pulse-soft": "pulse-soft 3s ease-in-out infinite",
        twinkle: "twinkle 2.8s ease-in-out infinite",
      },
    },
  },
  plugins: [],
};

export default config;
