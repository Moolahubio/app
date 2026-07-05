import { useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import { useLocation } from "wouter";
import { PauseCircle, Trash2, AlertCircle } from "lucide-react";
import { Card, Button } from "@/components/ui";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogFooter,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import {
  useDeactivateAccount,
  useDeleteAccount,
  getGetMeQueryKey,
} from "@workspace/api-client-react";
import { useQueryClient } from "@tanstack/react-query";
import { apiErrorMessage } from "@/lib/utils";
import { useStepUpGate } from "@/components/app/StepUpDialog";

export function ManageAccountCard() {
  const { t } = useTranslation("account");
  const [, setLocation] = useLocation();
  const queryClient = useQueryClient();
  const deactivate = useDeactivateAccount();
  const deleteAccount = useDeleteAccount();
  const { requestProof, stepUpDialog } = useStepUpGate();

  const [showDeactivate, setShowDeactivate] = useState(false);
  const [showDelete, setShowDelete] = useState(false);
  const [confirmText, setConfirmText] = useState("");
  const [error, setError] = useState<string | null>(null);

  const finishSignedOut = () => {
    queryClient.setQueryData(getGetMeQueryKey(), null);
    queryClient.removeQueries({
      predicate: (q) => q.queryKey[0] !== getGetMeQueryKey()[0],
    });
    setLocation("/login");
  };

  const handleDeactivate = async () => {
    setError(null);
    const proof = await requestProof();
    if (!proof) return;
    try {
      await deactivate.mutateAsync({ data: proof });
      setShowDeactivate(false);
      finishSignedOut();
    } catch (err) {
      setError(apiErrorMessage(err) ?? t("manageAccount.deactivate.error"));
    }
  };

  const handleDelete = async () => {
    setError(null);
    const proof = await requestProof();
    if (!proof) return;
    try {
      await deleteAccount.mutateAsync({ data: { confirm: "DELETE", ...proof } });
      setShowDelete(false);
      finishSignedOut();
    } catch (err) {
      setError(apiErrorMessage(err) ?? t("manageAccount.delete.error"));
    }
  };

  return (
    <Card className="overflow-hidden p-1">
      <div className="divide-y divide-border">
        <button
          type="button"
          onClick={() => {
            setError(null);
            setShowDeactivate(true);
          }}
          className="flex w-full items-center justify-between px-4 py-3.5 text-start transition-colors hover:bg-accent"
        >
          <div className="flex items-center gap-3">
            <span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-muted text-foreground">
              <PauseCircle className="h-5 w-5" />
            </span>
            <div>
              <p className="text-sm font-semibold text-foreground">{t("manageAccount.deactivate.label")}</p>
              <p className="text-xs text-muted-foreground">
                {t("manageAccount.deactivate.detail")}
              </p>
            </div>
          </div>
        </button>

        <button
          type="button"
          onClick={() => {
            setError(null);
            setConfirmText("");
            setShowDelete(true);
          }}
          className="flex w-full items-center justify-between px-4 py-3.5 text-left transition-colors hover:bg-red-50 dark:hover:bg-red-500/10"
        >
          <div className="flex items-center gap-3">
            <span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-red-50 text-red-600 dark:bg-red-500/15 dark:text-red-400">
              <Trash2 className="h-5 w-5" />
            </span>
            <div>
              <p className="text-sm font-semibold text-red-600 dark:text-red-400">
                {t("manageAccount.delete.label")}
              </p>
              <p className="text-xs text-muted-foreground">
                {t("manageAccount.delete.detail")}
              </p>
            </div>
          </div>
        </button>
      </div>

      {/* Deactivate dialog */}
      <Dialog open={showDeactivate} onOpenChange={setShowDeactivate}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t("manageAccount.deactivate.dialogTitle")}</DialogTitle>
            <DialogDescription>
              {t("manageAccount.deactivate.dialogDescription")}
            </DialogDescription>
          </DialogHeader>
          {error && (
            <p className="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
              <AlertCircle className="h-4 w-4 shrink-0" /> {error}
            </p>
          )}
          <DialogFooter>
            <Button variant="ghost" onClick={() => setShowDeactivate(false)}>
              {t("common:actions.cancel")}
            </Button>
            <Button onClick={handleDeactivate} disabled={deactivate.isPending}>
              {deactivate.isPending ? t("manageAccount.deactivate.pending") : t("manageAccount.deactivate.action")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Delete dialog */}
      <Dialog open={showDelete} onOpenChange={setShowDelete}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t("manageAccount.delete.dialogTitle")}</DialogTitle>
            <DialogDescription>
              <Trans
                t={t}
                i18nKey="manageAccount.delete.dialogDescription"
                components={{ strong: <span className="font-semibold text-foreground" /> }}
              />
            </DialogDescription>
          </DialogHeader>
          <input
            value={confirmText}
            onChange={(e) => setConfirmText(e.target.value)}
            placeholder="DELETE"
            className="w-full rounded-xl border border-border bg-background px-3.5 py-2.5 text-sm text-foreground outline-none focus:border-red-500/60 focus-ring"
          />
          {error && (
            <p className="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
              <AlertCircle className="h-4 w-4 shrink-0" /> {error}
            </p>
          )}
          <DialogFooter>
            <Button variant="ghost" onClick={() => setShowDelete(false)}>
              {t("common:actions.cancel")}
            </Button>
            <Button
              variant="primary"
              onClick={handleDelete}
              disabled={deleteAccount.isPending || confirmText.trim() !== "DELETE"}
              className="bg-red-600 hover:bg-red-500"
            >
              {deleteAccount.isPending ? t("manageAccount.delete.pending") : t("manageAccount.delete.action")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {stepUpDialog}
    </Card>
  );
}
