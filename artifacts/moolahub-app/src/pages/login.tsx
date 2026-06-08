import { useEffect } from "react";
import { useLocation } from "wouter";
import { AuthShell } from "@/components/auth/AuthShell";
import { AuthPanel } from "@/components/auth/AuthPanel";
import { useAuth } from "@/hooks/use-auth";

export default function Login() {
  const { isAuthenticated, isLoading } = useAuth();
  const [, setLocation] = useLocation();

  useEffect(() => {
    if (!isLoading && isAuthenticated) {
      setLocation("/");
    }
  }, [isLoading, isAuthenticated, setLocation]);

  if (!isLoading && isAuthenticated) {
    return null;
  }

  return (
    <AuthShell>
      <AuthPanel />
    </AuthShell>
  );
}
