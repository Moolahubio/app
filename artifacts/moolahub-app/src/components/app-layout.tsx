import { Link, useLocation } from "wouter";
import { useAuth } from "@/hooks/use-auth";
import { useLogout } from "@workspace/api-client-react";
import { useEffect } from "react";
import { 
  Home, 
  Wallet, 
  Users, 
  Target, 
  BookOpen, 
  Activity, 
  Bell, 
  User, 
  LogOut 
} from "lucide-react";

export function AppLayout({ children }: { children: React.ReactNode }) {
  const { isAuthenticated, isLoading } = useAuth();
  const [, setLocation] = useLocation();

  useEffect(() => {
    if (!isLoading && !isAuthenticated) {
      setLocation("/login");
    }
  }, [isLoading, isAuthenticated, setLocation]);
  
  if (isLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-background">
        <div className="text-muted-foreground text-sm">Loading...</div>
      </div>
    );
  }
  
  if (!isAuthenticated) {
    return null;
  }

  return (
    <div className="min-h-screen flex bg-background">
      <Sidebar />
      <main className="flex-1 pb-16 md:pb-0 overflow-y-auto">
        <div className="max-w-5xl mx-auto p-4 md:p-8">
          {children}
        </div>
      </main>
      <BottomNav />
    </div>
  );
}

function Sidebar() {
  const [location, setLocation] = useLocation();
  const logout = useLogout();

  const navItems = [
    { icon: Home, label: "Dashboard", href: "/dashboard" },
    { icon: Wallet, label: "Wallet", href: "/wallet" },
    { icon: Users, label: "Circles", href: "/circles" },
    { icon: Target, label: "Goals", href: "/goals" },
    { icon: BookOpen, label: "Learn", href: "/learn" },
    { icon: Activity, label: "Activity", href: "/activity" },
  ];

  return (
    <div className="hidden md:flex w-64 flex-col border-r bg-card h-screen sticky top-0">
      <div className="p-6">
        <h1 className="text-2xl font-bold text-primary tracking-tight">MoolaHub</h1>
      </div>
      
      <nav className="flex-1 px-4 space-y-2">
        {navItems.map((item) => {
          const isActive = location === item.href;
          return (
            <Link key={item.href} href={item.href} className={`flex items-center gap-3 px-4 py-3 rounded-xl transition-colors ${isActive ? "bg-primary/10 text-primary font-medium" : "text-muted-foreground hover:bg-secondary hover:text-foreground"}`}>
              <item.icon className="w-5 h-5" />
              {item.label}
            </Link>
          );
        })}
      </nav>

      <div className="p-4 space-y-2 border-t">
        <Link href="/notifications" className="flex items-center gap-3 px-4 py-3 rounded-xl text-muted-foreground hover:bg-secondary hover:text-foreground">
          <Bell className="w-5 h-5" />
          Notifications
        </Link>
        <Link href="/profile" className="flex items-center gap-3 px-4 py-3 rounded-xl text-muted-foreground hover:bg-secondary hover:text-foreground">
          <User className="w-5 h-5" />
          Profile
        </Link>
        <button onClick={() => logout.mutate(undefined, { onSuccess: () => setLocation("/login") })} className="w-full flex items-center gap-3 px-4 py-3 rounded-xl text-muted-foreground hover:bg-destructive/10 hover:text-destructive transition-colors">
          <LogOut className="w-5 h-5" />
          Logout
        </button>
      </div>
    </div>
  );
}

function BottomNav() {
  const [location] = useLocation();
  
  const navItems = [
    { icon: Home, label: "Home", href: "/dashboard" },
    { icon: Wallet, label: "Wallet", href: "/wallet" },
    { icon: Users, label: "Circles", href: "/circles" },
    { icon: Target, label: "Goals", href: "/goals" },
  ];

  return (
    <div className="md:hidden fixed bottom-0 left-0 right-0 border-t bg-card pb-safe z-50">
      <div className="flex justify-around p-2">
        {navItems.map((item) => {
          const isActive = location === item.href;
          return (
            <Link key={item.href} href={item.href} className={`flex flex-col items-center justify-center p-2 rounded-lg min-w-[64px] ${isActive ? "text-primary" : "text-muted-foreground"}`}>
              <item.icon className="w-6 h-6 mb-1" />
              <span className="text-[10px] font-medium">{item.label}</span>
            </Link>
          );
        })}
      </div>
    </div>
  );
}
