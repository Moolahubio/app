import { useListGoals, useCreateGoal, getListGoalsQueryKey } from "@workspace/api-client-react";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { formatMoney } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Link } from "wouter";
import { useQueryClient } from "@tanstack/react-query";
import { useToast } from "@/hooks/use-toast";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useState } from "react";
import { Progress } from "@/components/ui/progress";

export default function Goals() {
  const { data: goals, isLoading } = useListGoals();
  const queryClient = useQueryClient();
  const { toast } = useToast();
  const createMutation = useCreateGoal();

  const [isOpen, setIsOpen] = useState(false);
  const [name, setName] = useState("");
  const [target, setTarget] = useState("");
  const [deadline, setDeadline] = useState("");

  const handleCreate = (e: React.FormEvent) => {
    e.preventDefault();
    createMutation.mutate(
      { 
        data: { 
          name, 
          targetCents: Math.floor(parseFloat(target) * 100), 
          deadline: new Date(deadline).toISOString()
        } 
      },
      {
        onSuccess: () => {
          queryClient.invalidateQueries({ queryKey: getListGoalsQueryKey() });
          toast({ title: "Success", description: "Goal created" });
          setIsOpen(false);
        }
      }
    );
  };

  if (isLoading) return <div className="p-8">Loading...</div>;

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-3xl font-bold tracking-tight">Savings Goals</h1>
        <Dialog open={isOpen} onOpenChange={setIsOpen}>
          <DialogTrigger asChild>
            <Button>New Goal</Button>
          </DialogTrigger>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>Create a savings goal</DialogTitle>
            </DialogHeader>
            <form onSubmit={handleCreate} className="space-y-4 pt-4">
              <div className="space-y-2">
                <Label>Goal Name</Label>
                <Input value={name} onChange={e => setName(e.target.value)} required placeholder="Emergency Fund" />
              </div>
              <div className="space-y-2">
                <Label>Target Amount (USD)</Label>
                <Input type="number" value={target} onChange={e => setTarget(e.target.value)} required placeholder="1000" />
              </div>
              <div className="space-y-2">
                <Label>Target Date</Label>
                <Input type="date" value={deadline} onChange={e => setDeadline(e.target.value)} required />
              </div>
              <Button type="submit" className="w-full" disabled={createMutation.isPending}>
                Create Goal
              </Button>
            </form>
          </DialogContent>
        </Dialog>
      </div>

      {!goals || goals.length === 0 ? (
        <Card>
          <CardContent className="p-8 text-center text-muted-foreground">
            No goals yet. Create one to start saving!
          </CardContent>
        </Card>
      ) : (
        <div className="grid md:grid-cols-2 gap-4">
          {goals.map(goal => {
            const percent = Math.min(100, Math.round((goal.savedCents / goal.targetCents) * 100));
            return (
              <Link key={goal.id} href={`/goals/${goal.id}`}>
                <Card className="hover:border-primary/50 transition-colors cursor-pointer h-full">
                  <CardContent className="pt-6">
                    <div className="flex justify-between items-start mb-4">
                      <div className="flex items-center gap-2">
                        {goal.emoji && <span className="text-2xl">{goal.emoji}</span>}
                        <h3 className="font-semibold text-lg">{goal.name}</h3>
                      </div>
                      <div className="text-right">
                        <div className="font-bold">{percent}%</div>
                      </div>
                    </div>
                    
                    <Progress value={percent} className="h-2 mb-2" />
                    
                    <div className="flex justify-between text-sm text-muted-foreground">
                      <span>{formatMoney(goal.savedCents)} saved</span>
                      <span>{formatMoney(goal.targetCents)} goal</span>
                    </div>
                  </CardContent>
                </Card>
              </Link>
            );
          })}
        </div>
      )}
    </div>
  );
}
