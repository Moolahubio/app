import { useTranslation } from "react-i18next";
import { PageHeader, BackLink } from "@/components/app/bits";
import { PasskeysCard } from "@/components/app/PasskeysCard";
import { TwoFactorCard } from "@/components/app/TwoFactorCard";
import { ChangePasswordCard } from "@/components/app/ChangePasswordCard";

export default function ProfileSecurityPage() {
  const { t } = useTranslation("account");
  return (
    <div className="mx-auto max-w-2xl space-y-6">
      <BackLink href="/profile" label={t("common:nav.account")} />
      <PageHeader
        eyebrow={t("security.eyebrow")}
        title={t("security.title")}
        description={t("security.description")}
      />
      <ChangePasswordCard />
      <PasskeysCard />
      <TwoFactorCard />
    </div>
  );
}
