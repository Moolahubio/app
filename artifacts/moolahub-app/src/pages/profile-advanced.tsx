import { useTranslation } from "react-i18next";
import { Wrench } from "lucide-react";
import { Card } from "@/components/ui";
import { Switch } from "@/components/ui/switch";
import { PageHeader, BackLink } from "@/components/app/bits";
import { useTechnicalDetails } from "@/hooks/use-technical-details";

/**
 * Settings → Advanced. Home of the Technical details toggle: off by default,
 * any user can turn it on, and the app never requires it (spec §1).
 */
export default function ProfileAdvancedPage() {
  const { t } = useTranslation("account");
  const [technical, setTechnical] = useTechnicalDetails();

  return (
    <div className="mx-auto max-w-2xl space-y-6">
      <BackLink href="/profile" label={t("common:nav.account")} />
      <PageHeader
        eyebrow={t("sections.settings")}
        title={t("advanced.title")}
        description={t("advanced.description")}
      />

      <Card className="p-5">
        <div className="flex items-start justify-between gap-4">
          <div className="flex items-start gap-3">
            <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-muted text-foreground">
              <Wrench className="h-5 w-5" />
            </span>
            <div>
              <label htmlFor="technical-details" className="text-sm font-semibold text-foreground">
                {t("advanced.technicalLabel")}
              </label>
              <p className="mt-0.5 text-xs text-muted-foreground">{t("advanced.technicalDescription")}</p>
              <p className="mt-2 text-[11px] text-muted-foreground">{t("advanced.savedNote")}</p>
            </div>
          </div>
          <div className="flex shrink-0 items-center gap-2">
            <span className="text-xs text-muted-foreground">
              {technical ? t("twoFactor.on") : t("twoFactor.off")}
            </span>
            <Switch
              id="technical-details"
              checked={technical}
              onCheckedChange={(on) => setTechnical(on)}
            />
          </div>
        </div>
      </Card>
    </div>
  );
}
