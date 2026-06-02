import { useGetGoal, useAllocateToGoal, useReleaseFromGoal, getGetGoalQueryKey } from "@workspace/api-client-react";
import { Card, CardContent } from "@/components/ui/card";
import { formatMoney } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Link, useParams } from "wouter";
import { useQueryClient } from "@tanstack/react-query";
import { useToast } from "@/hooks/use-toast";
import { ChevronLeft } from "lucide-react";
import { Progress } from "@/components/ui/progress";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useState } from "react";
import { format } from "date-fns";

export default function GoalDetail() {
  const { id } = useParams();
  const { data: goal, isLoading } = useGetGoal(id!, { query: { enabled: !!id } });
  const queryClient = useQueryClient();
  const { toast } = useToast();
  
  const allocateMutation = useAllocateToGoal();
  const releaseMutation = useReleaseFromGoal();

  const [allocAmount, setAllocAmount] = useState("");
  const [releaseAmount, setReleaseAmount] = useState("");

  if (isLoading) return <div className="p-8">Loading...</div>;
  if (!goal) return <div className="p-8">Goal not found</div>;

  const percent = Math.min(100, Math.round((goal.savedCents / goal.targetCents) * 100));

  const handleAllocate = (e: React.FormEvent) => {
    e.preventDefault();
    allocateMutation.mutate(
      { id: goal.id, data: { amountCents: Math.floor(parseFloat(allocAmount) * 100) } },
      {
        onSuccess: () => {
          queryClient.invalidateQueries({ queryKey: getGetGoalQueryKey(goal.id) });
          toast({ title: "Success", description: "Funds allocated!" });
          setAllocAmount("");
        }
      }
    );
  };

  const handleRelease = (e: React.FormEvent) => {
    e.preventDefault();
    releaseMutation.mutate(
      { id: goal.id, data: { amountCents: Math.floor(parseFloat(releaseAmount) * 100) } },
      {
        onSuccess: () => {
          queryClient.invalidateQueries({ queryKey: getGetGoalQueryKey(goal.id) });
          toast({ title: "Success", description: "Funds released!" });
          setReleaseAmount("");
        }
      }
    );
  };

  return (
    <div className="space-y-6">
      <Link href="/goals" className="inline-flex items-center text-sm text-muted-foreground hover:text-foreground">
        <ChevronLeft className="w-4 h-4 mr-1" /> Back to Goals
      </Link>
      
      <div>
        <div className="flex items-center gap-3">
          {goal.emoji && <span className="text-4xl">{goal.emoji}</span>}
          <h1 className="text-3xl font-bold tracking-tight">{goal.name}</h1>
        </div>
        <p className="text-muted-foreground mt-2">Target date: {format(new Date(goal.deadline), "MMMM d, yyyy")}</p>
      </div>

      <Card className="border-primary/20">
        <CardContent className="pt-6 space-y-4">
          <div className="flex justify-between items-end">
            <div>
              <div className="text-sm text-muted-foreground mb-1">Current Progress</div>
              <div className="text-4xl font-bold text-primary">{formatMoney(goal.savedCents)}</div>
            </div>
            <div className="text-right">
              <div className="text-sm text-muted-foreground mb-1">Target</div>
              <div className="text-2xl font-semibold">{formatMoney(goal.targetCents)}</div>
            </div>
          </div>
          
          <div>
            <div className="flex justify-between text-sm font-medium mb-2">
              <span>{percent}%</span>
            </div>
            <Progress value={percent} className="h-3" />
          </div>
        </CardContent>
      </Card>

      <div className="grid md:grid-cols-2 gap-4">
        <Card>
          <CardContent className="pt-6">
            <h3 className="font-semibold mb-4">Allocate Funds</h3>
            <form onSubmit={handleAllocate} className="flex gap-2">
              <Input type="number" value={allocAmount} onChange={e => setAllocAmount(e.target.value)} placeholder="Amount to add" />
              <Button type="submit" disabled={allocateMutation.isPending || !allocAmount}>Add</Button>
            </form>
          </CardContent>
        </Card>

        <Card>
          <CardContent className="pt-6">
            <h3 className="font-semibold mb-4">Release Funds</h3>
            <form onSubmit={handleRelease} className="flex gap-2">
              <Input type="number" value={releaseAmount} onChange={e => setReleaseAmount(e.target.value)} placeholder="Amount to withdraw" />
              <Button variant="outline" type="submit" disabled={releaseMutation.isPending || !releaseAmount}>Release</Button>
            </form>
            <p className="text-xs text-muted-foreground mt-2">Releases funds back to your wallet available balance.</p>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
