import { Link } from "wouter";
import { Compass, ArrowLeft } from "lucide-react";
import { GlassCard, Button } from "@/components/ui";
import { useTranslation } from "react-i18next";

export default function NotFound() {
  const { t } = useTranslation("notifications");
  return (
    <div className="mh-bg-grid flex min-h-[100dvh] w-full items-center justify-center px-6 py-16">
      <GlassCard className="w-full max-w-md p-8 text-center md:p-10">
        <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-2xl bg-[color:var(--mh-mint)]/15 text-[color:var(--mh-jade)] dark:text-[color:var(--mh-mint)]">
          <Compass className="h-7 w-7" />
        </div>
        <p className="mh-kicker mt-6">404</p>
        <h1 className="mh-page-title mt-2 font-display text-2xl font-bold tracking-tight">
          {t("notFound.title")}
        </h1>
        <p className="mh-muted mt-3 text-sm">
          {t("notFound.description")}
        </p>
        <Link href="/">
          <Button size="lg" className="mt-8 w-full focus-ring">
            <ArrowLeft className="h-4 w-4 rtl:rotate-180" /> {t("notFound.backHome")}
          </Button>
        </Link>
      </GlassCard>
    </div>
  );
}
