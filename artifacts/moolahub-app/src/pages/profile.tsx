import { useState, useEffect } from "react";
import { useGetProfile, useUpdateProfile, getGetProfileQueryKey } from "@workspace/api-client-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useToast } from "@/hooks/use-toast";
import { useQueryClient } from "@tanstack/react-query";
import { Badge } from "@/components/ui/badge";

export default function Profile() {
  const { data: profile, isLoading } = useGetProfile();
  const updateMutation = useUpdateProfile();
  const queryClient = useQueryClient();
  const { toast } = useToast();

  const [name, setName] = useState("");

  useEffect(() => {
    if (profile) {
      setName(profile.name);
    }
  }, [profile]);

  if (isLoading) return <div className="p-8">Loading...</div>;
  if (!profile) return null;

  const handleUpdate = (e: React.FormEvent) => {
    e.preventDefault();
    if (name === profile.name) return;

    updateMutation.mutate({ data: { name } }, {
      onSuccess: () => {
        queryClient.invalidateQueries({ queryKey: getGetProfileQueryKey() });
        toast({ title: "Profile updated", description: "Your profile has been saved." });
      }
    });
  };

  return (
    <div className="space-y-6 max-w-2xl mx-auto">
      <h1 className="text-3xl font-bold tracking-tight">Profile</h1>

      <Card>
        <CardHeader>
          <CardTitle>Personal Information</CardTitle>
        </CardHeader>
        <CardContent>
          <form onSubmit={handleUpdate} className="space-y-4">
            <div className="space-y-2">
              <Label>Email</Label>
              <Input value={profile.email} disabled />
              <p className="text-xs text-muted-foreground">Email cannot be changed.</p>
            </div>
            
            <div className="space-y-2">
              <Label>Full Name</Label>
              <Input 
                value={name} 
                onChange={(e) => setName(e.target.value)} 
                required 
              />
            </div>

            <Button 
              type="submit" 
              disabled={updateMutation.isPending || name === profile.name}
            >
              Save Changes
            </Button>
          </form>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Account Status</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div>
            <Label className="text-muted-foreground mb-1 block">KYC Status</Label>
            <Badge variant="outline" className="capitalize px-3 py-1 text-sm">
              {profile.kycStatus}
            </Badge>
          </div>
          
          <div>
            <Label className="text-muted-foreground mb-1 block">Wallet Address</Label>
            {profile.walletAddress ? (
              <code className="bg-secondary p-2 rounded block text-sm break-all">
                {profile.walletAddress}
              </code>
            ) : (
              <span className="text-muted-foreground text-sm">No wallet connected</span>
            )}
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
