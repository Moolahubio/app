import { useEffect, useRef, useState } from "react";
import { Download, Share2 } from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import { Switch } from "@/components/ui/switch";
import { Button } from "@/components/ui";
import { formatMoney } from "@/lib/utils";

/**
 * Privacy-first share card. Renders the streak count to a PNG via canvas — no
 * dependency. Dollar amounts are NEVER drawn unless the user explicitly opts in
 * with the reveal toggle (default OFF).
 */
export function StreakShareCard({
  open,
  onOpenChange,
  count,
  caption,
  amountCents,
}: {
  open: boolean;
  onOpenChange: (v: boolean) => void;
  count: number;
  caption: string;
  amountCents?: number | null;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [showAmount, setShowAmount] = useState(false);

  // Reset the reveal toggle every time the dialog opens — privacy by default.
  useEffect(() => {
    if (open) setShowAmount(false);
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const canvas = canvasRef.current;
    if (!canvas) return;
    drawCard(canvas, {
      count,
      caption,
      amount: showAmount && amountCents != null ? formatMoney(amountCents) : null,
    });
  }, [open, count, caption, amountCents, showAmount]);

  const download = () => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    canvas.toBlob((blob) => {
      if (!blob) return;
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `moolahub-streak-${count}.png`;
      a.click();
      URL.revokeObjectURL(url);
    }, "image/png");
  };

  const share = async () => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    canvas.toBlob(async (blob) => {
      if (!blob) return;
      const file = new File([blob], `moolahub-streak-${count}.png`, { type: "image/png" });
      const nav = navigator as Navigator & { canShare?: (d: { files: File[] }) => boolean };
      if (nav.canShare?.({ files: [file] })) {
        try {
          await nav.share({ files: [file], title: "My MoolaHub streak" } as ShareData);
          return;
        } catch {
          /* user cancelled — fall through to download */
        }
      }
      download();
    }, "image/png");
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Share your streak</DialogTitle>
          <DialogDescription>
            Your card shows your streak count only. Dollar amounts stay private unless you turn them on.
          </DialogDescription>
        </DialogHeader>

        <div className="overflow-hidden rounded-2xl border border-border">
          <canvas ref={canvasRef} className="aspect-square w-full" />
        </div>

        {amountCents != null && (
          <label className="flex items-center justify-between rounded-xl border border-border bg-card px-4 py-3">
            <span className="text-sm font-medium text-foreground">Include amount saved</span>
            <Switch checked={showAmount} onCheckedChange={setShowAmount} />
          </label>
        )}

        <div className="flex gap-3">
          <Button variant="secondary" className="flex-1" onClick={download}>
            <Download className="h-4 w-4" /> Download
          </Button>
          <Button className="flex-1" onClick={() => void share()}>
            <Share2 className="h-4 w-4" /> Share
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}

function drawCard(
  canvas: HTMLCanvasElement,
  { count, caption, amount }: { count: number; caption: string; amount: string | null },
) {
  const ctx = canvas.getContext("2d");
  if (!ctx) return;
  const S = 1080;
  canvas.width = S;
  canvas.height = S;

  const g = ctx.createLinearGradient(0, 0, S, S);
  g.addColorStop(0, "#0C1512");
  g.addColorStop(1, "#0E6E50");
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, S, S);

  ctx.textAlign = "center";
  ctx.textBaseline = "middle";

  ctx.font = "220px serif";
  ctx.fillText("🔥", S / 2, S / 2 - 170);

  ctx.fillStyle = "#ffffff";
  ctx.font = "bold 320px Inter, system-ui, sans-serif";
  ctx.fillText(String(count), S / 2, S / 2 + 90);

  ctx.fillStyle = "rgba(255,255,255,0.82)";
  ctx.font = "500 50px Inter, system-ui, sans-serif";
  ctx.fillText(caption, S / 2, S / 2 + 270);

  if (amount) {
    ctx.fillStyle = "rgba(255,255,255,0.92)";
    ctx.font = "600 56px Inter, system-ui, sans-serif";
    ctx.fillText(`${amount} saved`, S / 2, S / 2 + 350);
  }

  ctx.fillStyle = "rgba(255,255,255,0.7)";
  ctx.font = "600 38px Inter, system-ui, sans-serif";
  ctx.fillText("MoolaHub · Save today, reach it together", S / 2, S - 80);
}
