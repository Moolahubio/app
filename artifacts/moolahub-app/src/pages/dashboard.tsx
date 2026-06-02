import { useGetDashboardSummary } from "@workspace/api-client-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { formatMoney } from "@/lib/utils";
import { Link } from "wouter";

export default function Dashboard() {
  const { data: summary, isLoading } = useGetDashboardSummary();

  if (isLoading) {
    return <div className="p-8">Loading dashboard...</div>;
  }

  if (!summary) return null;

  return (
    <div className="space-y-6">
      <h1 className="text-3xl font-bold tracking-tight">Dashboard</h1>
      
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        <Card className="bg-primary text-primary-foreground">
          <CardHeader className="pb-2">
            <CardTitle className="text-lg font-medium opacity-90">Total Balance</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-4xl font-bold">{formatMoney(summary.totalCents)}</div>
            <div className="mt-2 text-sm opacity-80">
              {formatMoney(summary.availableCents)} available
            </div>
          </CardContent>
        </Card>

        <div className="grid grid-cols-2 gap-4">
          <Card>
            <CardHeader className="pb-2">
              <CardTitle className="text-sm font-medium text-muted-foreground">Goals</CardTitle>
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold">{formatMoney(summary.goalTotalCents)}</div>
              <p className="text-xs text-muted-foreground mt-1">{summary.activeGoals.length} active goals</p>
            </CardContent>
          </Card>
          <Card>
            <CardHeader className="pb-2">
              <CardTitle className="text-sm font-medium text-muted-foreground">Circles Pot</CardTitle>
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold">{formatMoney(summary.circlePotCents)}</div>
              <p className="text-xs text-muted-foreground mt-1">{summary.activeCircles.length} active circles</p>
            </CardContent>
          </Card>
        </div>
      </div>
      
      <div className="grid md:grid-cols-2 gap-6">
        <div className="space-y-4">
          <h2 className="text-xl font-semibold">Recent Activity</h2>
          {summary.recentActivity.length === 0 ? (
            <Card>
              <CardContent className="p-8 text-center text-muted-foreground">
                No recent activity.
              </CardContent>
            </Card>
          ) : (
            <div className="space-y-3">
              {summary.recentActivity.map(activity => (
                <div key={activity.id} className="flex justify-between items-center p-3 rounded-lg border bg-card">
                  <div>
                    <div className="font-medium">{activity.description}</div>
                    <div className="text-xs text-muted-foreground">{new Date(activity.createdAt).toLocaleDateString()}</div>
                  </div>
                  {activity.amountCents && (
                    <div className="font-bold">{formatMoney(activity.amountCents)}</div>
                  )}
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
