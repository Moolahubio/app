import { useGetWallet, useDepositFaucet, useWithdrawFunds, useSyncDeposits, useGetOnrampUrl, getGetWalletQueryKey } from "@workspace/api-client-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { formatMoney } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { useToast } from "@/hooks/use-toast";
import { useQueryClient } from "@tanstack/react-query";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useState } from "react";
import { Loader2 } from "lucide-react";

export default function Wallet() {
  const { data: wallet, isLoading } = useGetWallet();
  const { data: onrampData } = useGetOnrampUrl({ query: { enabled: !!wallet?.onrampEnabled } });
  
  const queryClient = useQueryClient();
  const { toast } = useToast();
  
  const depositMutation = useDepositFaucet();
  const withdrawMutation = useWithdrawFunds();
  const syncMutation = useSyncDeposits();
  
  const [withdrawAmount, setWithdrawAmount] = useState("");
  const [withdrawDest, setWithdrawDest] = useState("");

  if (isLoading) return <div className="p-8 flex justify-center"><Loader2 className="animate-spin" /></div>;
  if (!wallet) return null;

  return (
    <div className="space-y-6">
      <h1 className="text-3xl font-bold tracking-tight">Wallet</h1>
      
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        <Card className="bg-primary text-primary-foreground">
          <CardHeader className="pb-2">
            <CardTitle className="text-lg font-medium opacity-90">Available Balance</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-4xl font-bold">{formatMoney(wallet.availableCents)} USDC</div>
            <div className="mt-2 text-sm opacity-80">
              Total: {formatMoney(wallet.totalCents)} USDC | Allocated to goals: {formatMoney(wallet.goalAllocatedCents)} USDC
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-lg font-medium">Wallet Details</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2">
            <div className="text-sm">
              <span className="text-muted-foreground">Address:</span> <br/>
              <span className="font-mono text-xs bg-secondary p-1 rounded break-all">{wallet.address}</span>
            </div>
            <div className="text-sm">
              <span className="text-muted-foreground">Network:</span> <span className="font-medium capitalize">{wallet.network}</span>
            </div>
          </CardContent>
        </Card>
      </div>

      <div className="grid md:grid-cols-2 lg:grid-cols-4 gap-4">
        <Button 
          variant="outline" 
          className="h-24 flex-col gap-2"
          onClick={() => {
            depositMutation.mutate({ data: { amountCents: 10000 } }, {
              onSuccess: () => {
                queryClient.invalidateQueries({ queryKey: getGetWalletQueryKey() });
                toast({ title: "Deposited", description: "$100 added from faucet" });
              }
            });
          }}
          disabled={depositMutation.isPending}
        >
          Get Testnet Faucet
        </Button>
        
        <Dialog>
          <DialogTrigger asChild>
            <Button variant="outline" className="h-24 flex-col gap-2">
              Withdraw
            </Button>
          </DialogTrigger>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>Withdraw Funds</DialogTitle>
            </DialogHeader>
            <div className="space-y-4 py-4">
              <div className="space-y-2">
                <Label>Amount (USD)</Label>
                <Input type="number" value={withdrawAmount} onChange={e => setWithdrawAmount(e.target.value)} placeholder="0.00" />
              </div>
              <div className="space-y-2">
                <Label>Destination Address</Label>
                <Input value={withdrawDest} onChange={e => setWithdrawDest(e.target.value)} placeholder="0x..." />
              </div>
              <Button 
                className="w-full" 
                disabled={withdrawMutation.isPending || !withdrawAmount || !withdrawDest}
                onClick={() => {
                  withdrawMutation.mutate({ 
                    data: { amountCents: Math.floor(parseFloat(withdrawAmount) * 100), destination: withdrawDest } 
                  }, {
                    onSuccess: () => {
                      queryClient.invalidateQueries({ queryKey: getGetWalletQueryKey() });
                      toast({ title: "Withdrawn", description: "Funds successfully withdrawn" });
                    }
                  });
                }}
              >
                Confirm Withdrawal
              </Button>
            </div>
          </DialogContent>
        </Dialog>

        <Button 
          variant="outline" 
          className="h-24 flex-col gap-2"
          onClick={() => {
            syncMutation.mutate(undefined, {
              onSuccess: (res) => {
                queryClient.invalidateQueries({ queryKey: getGetWalletQueryKey() });
                toast({ title: "Synced", description: `Credited ${formatMoney(res.credited)} from chain` });
              }
            });
          }}
          disabled={syncMutation.isPending || !wallet.onchainEnabled}
        >
          Sync On-Chain
        </Button>

        <Button 
          variant="outline" 
          className="h-24 flex-col gap-2"
          disabled={!wallet.onrampEnabled || !onrampData?.url}
          onClick={() => {
            if (onrampData?.url) {
              window.open(onrampData.url, "_blank");
            }
          }}
        >
          Buy USDC (Onramp)
        </Button>
      </div>
    </div>
  );
}
