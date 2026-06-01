import Link from "next/link";
import { Logo } from "@/components/brand/Logo";
import { Button } from "@/components/ui";

const links = [
  { label: "Circles", href: "#circles" },
  { label: "Goals", href: "#goals" },
  { label: "Learn", href: "#learn" },
  { label: "On-chain", href: "#verification" },
];

export function SiteNav() {
  return (
    <header className="absolute inset-x-0 top-0 z-50">
      <nav className="mx-auto flex max-w-7xl items-center justify-between px-6 py-5 lg:px-8">
        <Link href="/" aria-label="MoolaHub home">
          <Logo tone="light" />
        </Link>

        <div className="hidden items-center gap-8 md:flex">
          {links.map((l) => (
            <a
              key={l.href}
              href={l.href}
              className="text-sm font-medium text-white/70 transition-colors hover:text-white"
            >
              {l.label}
            </a>
          ))}
        </div>

        <div className="flex items-center gap-3">
          <Link
            href="/app"
            className="hidden text-sm font-medium text-white/70 transition-colors hover:text-white sm:block"
          >
            Sign in
          </Link>
          <Button href="/get-started" size="sm">
            Get started
          </Button>
        </div>
      </nav>
    </header>
  );
}
