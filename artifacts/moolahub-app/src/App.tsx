import { Switch, Route, Router as WouterRouter } from "wouter";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Toaster } from "@/components/ui/toaster";
import { TooltipProvider } from "@/components/ui/tooltip";
import { AuthProvider } from "@/hooks/use-auth";
import { ThemeProvider } from "@/hooks/use-theme";
import { AppLayout } from "@/components/app-layout";
import NotFound from "@/pages/not-found";

import Login from "@/pages/login";
import Register from "@/pages/register";
import Dashboard from "@/pages/dashboard";
import Wallet from "@/pages/wallet";
import Circles from "@/pages/circles";
import CircleDetail from "@/pages/circle-detail";
import Goals from "@/pages/goals";
import GoalDetail from "@/pages/goal-detail";
import Learn from "@/pages/learn";
import LessonDetail from "@/pages/lesson-detail";
import Activity from "@/pages/activity";
import Notifications from "@/pages/notifications";
import Profile from "@/pages/profile";

const queryClient = new QueryClient();

function ProtectedRoute({ component: Component }: { component: any }) {
  return (
    <AppLayout>
      <Component />
    </AppLayout>
  );
}

function Router() {
  return (
    <Switch>
      <Route path="/login" component={Login} />
      <Route path="/register" component={Register} />
      <Route path="/dashboard">
        <ProtectedRoute component={Dashboard} />
      </Route>
      <Route path="/wallet">
        <ProtectedRoute component={Wallet} />
      </Route>
      <Route path="/circles">
        <ProtectedRoute component={Circles} />
      </Route>
      <Route path="/circles/:id">
        <ProtectedRoute component={CircleDetail} />
      </Route>
      <Route path="/goals">
        <ProtectedRoute component={Goals} />
      </Route>
      <Route path="/goals/new">
        <ProtectedRoute component={Goals} />
      </Route>
      <Route path="/goals/:id">
        <ProtectedRoute component={GoalDetail} />
      </Route>
      <Route path="/learn">
        <ProtectedRoute component={Learn} />
      </Route>
      <Route path="/learn/:slug">
        <ProtectedRoute component={LessonDetail} />
      </Route>
      <Route path="/activity">
        <ProtectedRoute component={Activity} />
      </Route>
      <Route path="/notifications">
        <ProtectedRoute component={Notifications} />
      </Route>
      <Route path="/profile">
        <ProtectedRoute component={Profile} />
      </Route>
      <Route path="/">
        <ProtectedRoute component={Dashboard} />
      </Route>
      <Route component={NotFound} />
    </Switch>
  );
}

function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <ThemeProvider>
        <TooltipProvider>
          <AuthProvider>
            <WouterRouter base={import.meta.env.BASE_URL.replace(/\/$/, "")}>
              <Router />
            </WouterRouter>
          </AuthProvider>
          <Toaster />
        </TooltipProvider>
      </ThemeProvider>
    </QueryClientProvider>
  );
}

export default App;
