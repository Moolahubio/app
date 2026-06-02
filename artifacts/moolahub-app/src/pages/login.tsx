import { useState } from "react";
import { Link, useLocation } from "wouter";
import { useLogin, usePrivyAuth } from "@workspace/api-client-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useToast } from "@/hooks/use-toast";

export default function Login() {
  const [, setLocation] = useLocation();
  const { toast } = useToast();
  const loginMutation = useLogin();
  const privyAuthMutation = usePrivyAuth();

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    loginMutation.mutate(
      { data: { email, password } },
      {
        onSuccess: () => {
          setLocation("/dashboard");
        },
        onError: (err: any) => {
          toast({
            title: "Error",
            description: err.error || "Failed to login",
            variant: "destructive"
          });
        }
      }
    );
  };

  const handlePrivyLogin = () => {
    toast({
      title: "Connect wallet via Privy",
      description: "Privy integration coming soon.",
    });
  };

  return (
    <div className="min-h-screen flex flex-col items-center justify-center bg-background p-4">
      <div className="w-full max-w-md bg-card border rounded-2xl shadow-sm p-8 space-y-8">
        <div className="text-center space-y-2">
          <h1 className="text-3xl font-bold text-primary tracking-tight">MoolaHub</h1>
          <p className="text-muted-foreground">Welcome back to your savings community</p>
        </div>

        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="email">Email</Label>
            <Input 
              id="email" 
              type="email" 
              placeholder="you@example.com" 
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              required
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="password">Password</Label>
            <Input 
              id="password" 
              type="password" 
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
            />
          </div>

          <Button type="submit" className="w-full" size="lg" disabled={loginMutation.isPending}>
            {loginMutation.isPending ? "Signing in..." : "Sign In"}
          </Button>
        </form>

        <div className="relative">
          <div className="absolute inset-0 flex items-center">
            <span className="w-full border-t" />
          </div>
          <div className="relative flex justify-center text-xs uppercase">
            <span className="bg-card px-2 text-muted-foreground">Or continue with</span>
          </div>
        </div>

        <Button variant="outline" type="button" className="w-full" size="lg" onClick={handlePrivyLogin}>
          Continue with Privy
        </Button>

        <p className="text-center text-sm text-muted-foreground">
          Don't have an account? <Link href="/register" className="text-primary hover:underline">Sign up</Link>
        </p>
      </div>
    </div>
  );
}
