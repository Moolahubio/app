import { PageHeader, BackLink } from "@/components/app/bits";
import { PasskeysCard } from "@/components/app/PasskeysCard";
import { TwoFactorCard } from "@/components/app/TwoFactorCard";
import { ChangePasswordCard } from "@/components/app/ChangePasswordCard";
import { PrivyLinkCard } from "@/components/app/PrivyLinkCard";

export default function ProfileSecurityPage() {
  return (
    <div className="mx-auto max-w-2xl space-y-6">
      <BackLink href="/profile" label="Account" />
      <PageHeader
        eyebrow="Security"
        title="Sign-in & security"
        description="Add extra layers of protection to your account."
      />
      <ChangePasswordCard />
      <PasskeysCard />
      <TwoFactorCard />
      <PrivyLinkCard />
    </div>
  );
}
