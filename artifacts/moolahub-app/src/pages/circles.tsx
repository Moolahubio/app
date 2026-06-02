import { useListCircles, useListInvites, useCreateCircle, useAcceptInvite, useDeclineInvite, getListCirclesQueryKey, getListInvitesQueryKey } from "@workspace/api-client-react";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { formatMoney } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Link } from "wouter";
import { useQueryClient } from "@tanstack/react-query";
import { useToast } from "@/hooks/use-toast";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { useState } from "react";
import { Badge } from "@/components/ui/badge";

export default function Circles() {
  const { data: circles, isLoading: circlesLoading } = useListCircles();
  const { data: invites, isLoading: invitesLoading } = useListInvites();
  
  const queryClient = useQueryClient();
  const { toast } = useToast();
  const createMutation = useCreateCircle();
  const acceptMutation = useAcceptInvite();
  const declineMutation = useDeclineInvite();

  const [isCreateOpen, setIsCreateOpen] = useState(false);
  const [name, setName] = useState("");
  const [contribution, setContribution] = useState("");
  const [frequency, setFrequency] = useState("weekly");
  const [emails, setEmails] = useState("");

  const handleCreate = (e: React.FormEvent) => {
    e.preventDefault();
    createMutation.mutate(
      { 
        data: { 
          name, 
          contributionCents: Math.floor(parseFloat(contribution) * 100), 
          frequency, 
          memberEmails: emails.split(",").map(e => e.trim()).filter(Boolean)
        } 
      },
      {
        onSuccess: () => {
          queryClient.invalidateQueries({ queryKey: getListCirclesQueryKey() });
          toast({ title: "Success", description: "Circle created successfully" });
          setIsCreateOpen(false);
        }
      }
    );
  };

  if (circlesLoading || invitesLoading) return <div className="p-8">Loading circles...</div>;

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-3xl font-bold tracking-tight">Circles</h1>
        <Dialog open={isCreateOpen} onOpenChange={setIsCreateOpen}>
          <DialogTrigger asChild>
            <Button>Create Circle</Button>
          </DialogTrigger>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>Create new Susu Circle</DialogTitle>
            </DialogHeader>
            <form onSubmit={handleCreate} className="space-y-4 pt-4">
              <div className="space-y-2">
                <Label>Name</Label>
                <Input value={name} onChange={e => setName(e.target.value)} required placeholder="Family Savings" />
              </div>
              <div className="space-y-2">
                <Label>Contribution Amount (USD)</Label>
                <Input type="number" value={contribution} onChange={e => setContribution(e.target.value)} required placeholder="100" />
              </div>
              <div className="space-y-2">
                <Label>Frequency</Label>
                <Select value={frequency} onValueChange={setFrequency}>
                  <SelectTrigger><SelectValue /></SelectTrigger>
                  <SelectContent>
                    <SelectItem value="weekly">Weekly</SelectItem>
                    <SelectItem value="biweekly">Bi-weekly</SelectItem>
                    <SelectItem value="monthly">Monthly</SelectItem>
                  </SelectContent>
                </Select>
              </div>
              <div className="space-y-2">
                <Label>Member Emails (comma separated)</Label>
                <Input value={emails} onChange={e => setEmails(e.target.value)} placeholder="friend@example.com, cousin@example.com" />
              </div>
              <Button type="submit" className="w-full" disabled={createMutation.isPending}>
                Create
              </Button>
            </form>
          </DialogContent>
        </Dialog>
      </div>

      {invites && invites.length > 0 && (
        <div className="space-y-4">
          <h2 className="text-xl font-semibold">Pending Invites</h2>
          <div className="grid md:grid-cols-2 gap-4">
            {invites.map(invite => (
              <Card key={invite.id}>
                <CardContent className="pt-6">
                  <div className="flex justify-between items-start mb-4">
                    <div>
                      <h3 className="font-semibold">{invite.circleName}</h3>
                      <p className="text-sm text-muted-foreground">Invited by {invite.inviterName}</p>
                    </div>
                    <div className="text-right">
                      <div className="font-medium">{formatMoney(invite.contributionCents)}</div>
                      <div className="text-xs text-muted-foreground capitalize">{invite.frequency}</div>
                    </div>
                  </div>
                  <div className="flex gap-2">
                    <Button 
                      className="flex-1" 
                      onClick={() => acceptMutation.mutate({ id: invite.id }, {
                        onSuccess: () => {
                          queryClient.invalidateQueries({ queryKey: getListInvitesQueryKey() });
                          queryClient.invalidateQueries({ queryKey: getListCirclesQueryKey() });
                        }
                      })}
                    >
                      Accept
                    </Button>
                    <Button 
                      variant="outline" 
                      className="flex-1"
                      onClick={() => declineMutation.mutate({ id: invite.id }, {
                        onSuccess: () => queryClient.invalidateQueries({ queryKey: getListInvitesQueryKey() })
                      })}
                    >
                      Decline
                    </Button>
                  </div>
                </CardContent>
              </Card>
            ))}
          </div>
        </div>
      )}

      <div className="space-y-4">
        <h2 className="text-xl font-semibold">My Circles</h2>
        {!circles || circles.length === 0 ? (
          <Card>
            <CardContent className="p-8 text-center text-muted-foreground">
              You are not part of any circles yet.
            </CardContent>
          </Card>
        ) : (
          <div className="grid md:grid-cols-2 gap-4">
            {circles.map(circle => (
              <Link key={circle.id} href={`/circles/${circle.id}`}>
                <Card className="hover:border-primary/50 transition-colors cursor-pointer h-full">
                  <CardContent className="pt-6">
                    <div className="flex justify-between items-start mb-4">
                      <div>
                        <h3 className="font-semibold text-lg">{circle.name}</h3>
                        <Badge variant="secondary" className="capitalize mt-1">{circle.status}</Badge>
                      </div>
                      <div className="text-right">
                        <div className="font-bold">{formatMoney(circle.potCents)} Pot</div>
                        <div className="text-xs text-muted-foreground">{formatMoney(circle.contributionCents)} {circle.frequency}</div>
                      </div>
                    </div>
                    
                    <div className="flex justify-between items-center text-sm">
                      <div className="text-muted-foreground">
                        {circle.memberCount} members
                      </div>
                      {circle.status === "active" && (
                        <div className="text-primary font-medium">
                          Round {circle.currentRound} / {circle.totalRounds}
                        </div>
                      )}
                    </div>
                  </CardContent>
                </Card>
              </Link>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
