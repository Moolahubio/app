import { useGetCircle, useStartCircle, useContributeToCircle, useInviteToCircle, getGetCircleQueryKey } from "@workspace/api-client-react";
import { Card, CardContent } from "@/components/ui/card";
import { formatMoney } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Link, useParams } from "wouter";
import { useQueryClient } from "@tanstack/react-query";
import { useToast } from "@/hooks/use-toast";
import { Badge } from "@/components/ui/badge";
import { ChevronLeft, CheckCircle2, Circle, UserPlus } from "lucide-react";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useState } from "react";

export default function CircleDetail() {
  const { id } = useParams();
  const { data: circle, isLoading } = useGetCircle(id!, { query: { enabled: !!id } });
  const queryClient = useQueryClient();
  const { toast } = useToast();
  
  const startMutation = useStartCircle();
  const contributeMutation = useContributeToCircle();
  const inviteMutation = useInviteToCircle();

  const [inviteEmail, setInviteEmail] = useState("");
  const [isInviteOpen, setIsInviteOpen] = useState(false);

  if (isLoading) return <div className="p-8">Loading...</div>;
  if (!circle) return <div className="p-8">Circle not found</div>;

  const isPending = circle.status === "pending";
  const isActive = circle.status === "active";
  const allAccepted = circle.members.every(m => m.state === "accepted");

  const handleInvite = (e: React.FormEvent) => {
    e.preventDefault();
    inviteMutation.mutate({ id: circle.id, data: { email: inviteEmail } }, {
      onSuccess: () => {
        toast({ title: "Success", description: "Invite sent!" });
        setInviteEmail("");
        setIsInviteOpen(false);
      }
    });
  };

  return (
    <div className="space-y-6">
      <Link href="/circles" className="inline-flex items-center text-sm text-muted-foreground hover:text-foreground">
        <ChevronLeft className="w-4 h-4 mr-1" /> Back to Circles
      </Link>
      
      <div className="flex flex-wrap justify-between items-start gap-4">
        <div>
          <h1 className="text-3xl font-bold tracking-tight">{circle.name}</h1>
          <div className="flex items-center gap-2 mt-2">
            <Badge className="capitalize">{circle.status}</Badge>
            <span className="text-muted-foreground text-sm">{circle.frequency} contributions</span>
          </div>
        </div>
        
        <div className="flex gap-2">
          {isPending && (
            <Dialog open={isInviteOpen} onOpenChange={setIsInviteOpen}>
              <DialogTrigger asChild>
                <Button variant="outline"><UserPlus className="w-4 h-4 mr-2" /> Invite</Button>
              </DialogTrigger>
              <DialogContent>
                <DialogHeader>
                  <DialogTitle>Invite to Circle</DialogTitle>
                </DialogHeader>
                <form onSubmit={handleInvite} className="space-y-4 pt-4">
                  <div className="space-y-2">
                    <Label>Email Address</Label>
                    <Input type="email" value={inviteEmail} onChange={e => setInviteEmail(e.target.value)} required placeholder="friend@example.com" />
                  </div>
                  <Button type="submit" className="w-full" disabled={inviteMutation.isPending}>
                    Send Invite
                  </Button>
                </form>
              </DialogContent>
            </Dialog>
          )}

          {isPending && allAccepted && (
            <Button 
              onClick={() => startMutation.mutate({ id: circle.id }, {
                onSuccess: () => {
                  queryClient.invalidateQueries({ queryKey: getGetCircleQueryKey(circle.id) });
                  toast({ title: "Success", description: "Circle started!" });
                }
              })}
              disabled={startMutation.isPending}
            >
              Start Circle
            </Button>
          )}

          {isActive && circle.myContributionStatus !== "paid" && (
            <Button 
              onClick={() => contributeMutation.mutate({ id: circle.id }, {
                onSuccess: () => {
                  queryClient.invalidateQueries({ queryKey: getGetCircleQueryKey(circle.id) });
                  toast({ title: "Success", description: "Contribution made!" });
                }
              })}
              disabled={contributeMutation.isPending}
            >
              Contribute {formatMoney(circle.contributionCents)}
            </Button>
          )}
        </div>
      </div>

      <div className="grid md:grid-cols-3 gap-4">
        <Card>
          <CardContent className="pt-6">
            <div className="text-sm text-muted-foreground mb-1">Total Pot</div>
            <div className="text-2xl font-bold">{formatMoney(circle.potCents)}</div>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-6">
            <div className="text-sm text-muted-foreground mb-1">Contribution</div>
            <div className="text-2xl font-bold">{formatMoney(circle.contributionCents)}</div>
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-6">
            <div className="text-sm text-muted-foreground mb-1">Progress</div>
            <div className="text-2xl font-bold">Round {circle.currentRound} / {circle.totalRounds}</div>
          </CardContent>
        </Card>
      </div>

      <div className="space-y-4">
        <h2 className="text-xl font-semibold">Members & Payout Order</h2>
        <Card>
          <div className="divide-y">
            {circle.members.map((member) => (
              <div key={member.id} className="p-4 flex items-center justify-between">
                <div className="flex items-center gap-4">
                  <div className="w-8 h-8 rounded-full bg-secondary flex items-center justify-center font-bold text-sm text-muted-foreground">
                    {member.payoutRound}
                  </div>
                  <div>
                    <div className="font-medium">{member.name} {member.myPayoutRound === member.payoutRound && "(You)"}</div>
                    <div className="text-xs text-muted-foreground capitalize">{member.state}</div>
                  </div>
                </div>
                
                <div className="text-right flex items-center gap-4">
                  {isActive && (
                    <div className="text-sm flex flex-col items-end">
                      <span className="text-muted-foreground text-xs mb-1">This Round</span>
                      {member.contributedThisRound ? (
                        <CheckCircle2 className="w-5 h-5 text-primary" />
                      ) : (
                        <Circle className="w-5 h-5 text-muted-foreground" />
                      )}
                    </div>
                  )}
                  {member.paidOut && (
                    <Badge variant="secondary">Paid Out</Badge>
                  )}
                </div>
              </div>
            ))}
          </div>
        </Card>
      </div>
    </div>
  );
}
