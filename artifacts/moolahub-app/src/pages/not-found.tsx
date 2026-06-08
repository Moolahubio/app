import { Link } from "wouter";
import { AlertCircle, ArrowLeft } from "lucide-react";
import { Card, Button } from "@/components/ui";

export default function NotFound() {
  return (
    <div className="flex min-h-[100dvh] w-full items-center justify-center bg-background px-6">
      <Card className="w-full max-w-md p-8 text-center">
        <div className="mx-auto flex h-12 w-12 items-center justify-center rounded-full bg-red-50 text-red-500 dark:bg-red-500/15 dark:text-red-400">
          <AlertCircle className="h-6 w-6" />
        </div>
        <h1 className="mt-4 font-display text-2xl font-bold tracking-tight text-foreground">
          Page not found
        </h1>
        <p className="mt-2 text-sm text-muted-foreground">
          The page you're looking for doesn't exist or may have moved.
        </p>
        <Link href="/">
          <Button size="lg" className="mt-6 w-full">
            <ArrowLeft className="h-4 w-4" /> Back to Home
          </Button>
        </Link>
      </Card>
    </div>
  );
}
