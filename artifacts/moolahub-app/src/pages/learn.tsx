import { useListLessons } from "@workspace/api-client-react";
import { Card, CardContent } from "@/components/ui/card";
import { Link } from "wouter";
import { CheckCircle2, Clock } from "lucide-react";
import { Badge } from "@/components/ui/badge";

export default function Learn() {
  const { data: lessons, isLoading } = useListLessons();

  if (isLoading) return <div className="p-8">Loading...</div>;

  return (
    <div className="space-y-6">
      <h1 className="text-3xl font-bold tracking-tight">Financial Education</h1>
      <p className="text-muted-foreground">Learn the basics of decentralized finance, stablecoins, and secure saving.</p>

      {!lessons || lessons.length === 0 ? (
        <Card>
          <CardContent className="p-8 text-center text-muted-foreground">
            No lessons available right now.
          </CardContent>
        </Card>
      ) : (
        <div className="grid md:grid-cols-2 gap-4">
          {lessons.map(lesson => (
            <Link key={lesson.slug} href={`/learn/${lesson.slug}`}>
              <Card className={`hover:border-primary/50 transition-colors cursor-pointer h-full ${lesson.completed ? 'bg-secondary/50' : ''}`}>
                <CardContent className="pt-6 flex flex-col h-full">
                  <div className="flex justify-between items-start mb-2">
                    <div className="flex items-center gap-2">
                      <span className="text-2xl">{lesson.emoji}</span>
                      <Badge variant={lesson.completed ? "secondary" : "default"} className="capitalize">{lesson.category}</Badge>
                    </div>
                    {lesson.completed && <CheckCircle2 className="w-5 h-5 text-primary" />}
                  </div>
                  
                  <h3 className="font-semibold text-lg mt-2 mb-1">{lesson.title}</h3>
                  <p className="text-sm text-muted-foreground flex-1 mb-4">{lesson.summary}</p>
                  
                  <div className="flex items-center text-xs text-muted-foreground font-medium uppercase tracking-wider">
                    <Clock className="w-3 h-3 mr-1" /> {lesson.minutes} min read
                    <span className="mx-2">•</span>
                    {lesson.level}
                  </div>
                </CardContent>
              </Card>
            </Link>
          ))}
        </div>
      )}
    </div>
  );
}
