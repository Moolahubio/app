import type { Metadata, Viewport } from "next";
import { Inter, Poppins, IBM_Plex_Mono } from "next/font/google";
import "./globals.css";

const inter = Inter({
  subsets: ["latin"],
  variable: "--font-sans",
  display: "swap",
});

const poppins = Poppins({
  subsets: ["latin"],
  weight: ["500", "600", "700", "800"],
  variable: "--font-display",
  display: "swap",
});

const plexMono = IBM_Plex_Mono({
  subsets: ["latin"],
  weight: ["400", "500", "600"],
  variable: "--font-mono",
  display: "swap",
});

export const metadata: Metadata = {
  title: {
    default: "MoolaHub — Save Now. Grow Together.",
    template: "%s · MoolaHub",
  },
  description:
    "MoolaHub is a non-custodial savings app built on Stellar. Save toward your goals, join trusted Susu circles, and grow together — every contribution verified on-chain.",
  keywords: [
    "MoolaHub",
    "Susu",
    "savings circle",
    "Stellar",
    "USDC",
    "group savings",
    "financial empowerment",
  ],
  openGraph: {
    title: "MoolaHub — Save Now. Grow Together.",
    description:
      "Non-custodial savings on Stellar. Goals, Susu circles, and financial education — verified on-chain.",
    siteName: "MoolaHub",
    type: "website",
  },
};

export const viewport: Viewport = {
  themeColor: "#0C1512",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html
      lang="en"
      className={`${inter.variable} ${poppins.variable} ${plexMono.variable}`}
    >
      <body className="font-sans antialiased">{children}</body>
    </html>
  );
}
