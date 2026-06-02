import { requireUser } from "@/lib/server/auth";
import { userBalances } from "@/lib/server/ledger";
import { getReminders } from "@/lib/server/reminders";
import { AppShell } from "@/components/app/AppShell";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const user = await requireUser();
  const [{ totalCents }, reminders] = await Promise.all([
    userBalances(user.id),
    getReminders(user.id),
  ]);
  const next = reminders[0];

  return (
    <AppShell
      user={{ name: user.name, kycStatus: user.kycStatus }}
      balanceCents={totalCents}
      reminder={
        next
          ? { title: next.title, amountCents: next.amountCents, dueDate: next.dueDate.toISOString() }
          : null
      }
    >
      {children}
    </AppShell>
  );
}
