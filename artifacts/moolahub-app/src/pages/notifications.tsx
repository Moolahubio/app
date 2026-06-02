import { useListNotifications, useMarkAllNotificationsRead, useMarkNotificationRead, useClearNotifications, getListNotificationsQueryKey } from "@workspace/api-client-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { useQueryClient } from "@tanstack/react-query";
import { format } from "date-fns";

export default function Notifications() {
  const { data, isLoading } = useListNotifications();
  const queryClient = useQueryClient();
  
  const markAllMutation = useMarkAllNotificationsRead();
  const markOneMutation = useMarkNotificationRead();
  const clearMutation = useClearNotifications();

  if (isLoading) return <div className="p-8">Loading...</div>;

  const notifications = data?.notifications || [];

  return (
    <div className="space-y-6">
      <div className="flex justify-between items-center">
        <h1 className="text-3xl font-bold tracking-tight">Notifications</h1>
        <div className="space-x-2">
          {data?.unreadCount ? (
            <Button 
              variant="outline" 
              onClick={() => markAllMutation.mutate(undefined, {
                onSuccess: () => queryClient.invalidateQueries({ queryKey: getListNotificationsQueryKey() })
              })}
              disabled={markAllMutation.isPending}
            >
              Mark all read
            </Button>
          ) : null}
          {notifications.length > 0 && (
            <Button 
              variant="outline" 
              onClick={() => clearMutation.mutate(undefined, {
                onSuccess: () => queryClient.invalidateQueries({ queryKey: getListNotificationsQueryKey() })
              })}
              disabled={clearMutation.isPending}
            >
              Clear all
            </Button>
          )}
        </div>
      </div>

      {notifications.length === 0 ? (
        <Card>
          <CardContent className="p-8 text-center text-muted-foreground">
            You're all caught up!
          </CardContent>
        </Card>
      ) : (
        <div className="space-y-3">
          {notifications.map((notif) => (
            <Card 
              key={notif.id} 
              className={`transition-colors ${notif.read ? 'opacity-70' : 'bg-primary/5 border-primary/20 cursor-pointer'}`}
              onClick={() => {
                if (!notif.read) {
                  markOneMutation.mutate({ id: notif.id }, {
                    onSuccess: () => queryClient.invalidateQueries({ queryKey: getListNotificationsQueryKey() })
                  });
                }
              }}
            >
              <CardContent className="p-4">
                <div className="flex justify-between items-start mb-1">
                  <h3 className={`font-semibold ${notif.read ? '' : 'text-primary'}`}>{notif.title}</h3>
                  <span className="text-xs text-muted-foreground">
                    {format(new Date(notif.createdAt), "MMM d, h:mm a")}
                  </span>
                </div>
                <p className="text-sm text-muted-foreground">{notif.body}</p>
                {notif.link && (
                  <div className="mt-2 text-sm text-primary hover:underline">
                    View details &rarr;
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
