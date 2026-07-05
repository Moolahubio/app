import { useEffect, useState } from "react";
import type { StreakBadge } from "@workspace/api-client-react";
import { Medal, Sparkles } from "lucide-react";
import { useTranslation } from "react-i18next";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui";

const SEEN_KEY = "moolahub.streakBadgesSeen";
const SEASON_KEY: Record<number, string> = { 1: "winter", 2: "spring", 3: "summer", 4: "autumn" };

function readSeen(): string[] | null {
  try {
    const raw = localStorage.getItem(SEEN_KEY);
    if (raw === null) return null;
    return JSON.parse(raw) as string[];
  } catch {
    return [];
  }
}

function writeSeen(keys: string[]): void {
  try {
    localStorage.setItem(SEEN_KEY, JSON.stringify(keys));
  } catch {
    /* ignore storage failures */
  }
}

/**
 * Celebrates newly-earned badges. On first ever load it silently records the
 * existing badges so we never surprise the user with historical milestones —
 * only badges earned after the feature is live trigger the celebration.
 */
export function StreakMilestoneModal({ badges }: { badges?: StreakBadge[] }) {
  const { t } = useTranslation("streak");
  const [active, setActive] = useState<StreakBadge | null>(null);

  useEffect(() => {
    if (!badges) return;
    const seen = readSeen();
    const allKeys = badges.map((b) => b.badgeKey);
    if (seen === null) {
      writeSeen(allKeys);
      return;
    }
    const unseen = badges.filter((b) => !seen.includes(b.badgeKey));
    if (unseen.length === 0) return;
    const newest = [...unseen].sort(
      (a, b) => new Date(b.earnedAt).getTime() - new Date(a.earnedAt).getTime(),
    )[0];
    setActive(newest);
  }, [badges]);

  const dismiss = () => {
    if (badges) writeSeen(badges.map((b) => b.badgeKey));
    setActive(null);
  };

  return (
    <Dialog open={active !== null} onOpenChange={(v) => !v && dismiss()}>
      <DialogContent className="sm:max-w-sm">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <Sparkles className="h-5 w-5 text-amber-500" /> {t("milestone.title")}
          </DialogTitle>
          <DialogDescription>
            {t("milestone.description")}
          </DialogDescription>
        </DialogHeader>
        {active && (
          <div className="flex flex-col items-center gap-3 py-4">
            <div className="flex h-24 w-24 items-center justify-center rounded-full bg-amber-500/15 text-amber-500">
              <Medal className="h-12 w-12" />
            </div>
            <p className="font-display text-lg font-bold text-foreground">
              {t(`season.${SEASON_KEY[active.quarterIndex]}`)} {active.year}
            </p>
            <p className="text-sm text-muted-foreground">{t("milestone.badgeUnlocked", { n: active.quarterIndex })}</p>
          </div>
        )}
        <Button onClick={dismiss}>{t("milestone.keepItUp")}</Button>
      </DialogContent>
    </Dialog>
  );
}
