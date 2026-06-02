import { useListActivity } from "@workspace/api-client-react";
import { Card, CardContent } from "@/components/ui/card";
import { formatMoney } from "@/lib/utils";
import { Badge } from "@/components/ui/badge";
import { format } from "date-fns";

export default function Activity() {
  const { data: activities, isLoading } = useListActivity();

  if (isLoading) return <div className="p-8">Loading...</div>;

  return (
    <div className="space-y-6">
      <h1 className="text-3xl font-bold tracking-tight">Activity History</h1>

      {!activities || activities.length === 0 ? (
        <Card>
          <CardContent className="p-8 text-center text-muted-foreground">
            No activity yet. Your transactions and updates will appear here.
          </CardContent>
        </Card>
      ) : (
        <div className="space-y-4">
          {activities.map((activity) => (
            <Card key={activity.id}>
              <CardContent className="p-4 flex justify-between items-center">
                <div className="flex flex-col">
                  <div className="flex items-center gap-2 mb-1">
                    <Badge variant="outline" className="capitalize">{activity.type}</Badge>
                    {activity.onchainStatus && (
                      <Badge variant="secondary" className="capitalize">{activity.onchainStatus}</Badge>
                    )}
                  </div>
                  <span className="font-medium">{activity.description}</span>
                  <span className="text-xs text-muted-foreground mt-1">
                    {format(new Date(activity.createdAt), "MMM d, yyyy 'at' h:mm a")}
                  </span>
                  {activity.txHash && (
                    <span className="text-xs font-mono text-muted-foreground mt-1 truncate max-w-[200px] md:max-w-xs">
                      Tx: {activity.txHash}
                    </span>
                  )}
                </div>
                {activity.amountCents != null && (
                  <div className="font-bold whitespace-nowrap ml-4">
                    {activity.amountCents > 0 ? "+" : ""}{formatMoney(activity.amountCents)}
                  </div>
                )}
              </CardContent>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}
