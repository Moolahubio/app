import { useGetLesson, useCompleteLesson, getGetLessonQueryKey, getListLessonsQueryKey } from "@workspace/api-client-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Link, useParams, useLocation } from "wouter";
import { useQueryClient } from "@tanstack/react-query";
import { ChevronLeft, CheckCircle2 } from "lucide-react";

export default function LessonDetail() {
  const { slug } = useParams();
  const [, setLocation] = useLocation();
  const { data: lesson, isLoading } = useGetLesson(slug!, { query: { enabled: !!slug } });
  const queryClient = useQueryClient();
  const completeMutation = useCompleteLesson();

  if (isLoading) return <div className="p-8">Loading...</div>;
  if (!lesson) return <div className="p-8">Lesson not found</div>;

  const handleComplete = () => {
    if (lesson.completed) {
      setLocation("/learn");
      return;
    }
    
    completeMutation.mutate({ slug: lesson.slug }, {
      onSuccess: () => {
        queryClient.invalidateQueries({ queryKey: getGetLessonQueryKey(lesson.slug) });
        queryClient.invalidateQueries({ queryKey: getListLessonsQueryKey() });
        setLocation("/learn");
      }
    });
  };

  return (
    <div className="space-y-8 max-w-3xl mx-auto">
      <Link href="/learn" className="inline-flex items-center text-sm text-muted-foreground hover:text-foreground">
        <ChevronLeft className="w-4 h-4 mr-1" /> Back to Lessons
      </Link>
      
      <div className="space-y-4">
        <div className="text-4xl">{lesson.emoji}</div>
        <h1 className="text-4xl font-bold tracking-tight">{lesson.title}</h1>
        <p className="text-xl text-muted-foreground">{lesson.summary}</p>
      </div>

      <div className="space-y-8">
        {lesson.body.map((section, idx) => (
          <section key={idx} className="space-y-3">
            <h2 className="text-2xl font-semibold">{section.heading}</h2>
            <div className="text-muted-foreground leading-relaxed">
              {section.text.split('\n').map((paragraph, i) => (
                <p key={i} className="mb-4">{paragraph}</p>
              ))}
            </div>
          </section>
        ))}
      </div>

      {lesson.takeaways && lesson.takeaways.length > 0 && (
        <Card className="bg-primary/5 border-primary/20">
          <CardContent className="pt-6">
            <h3 className="font-semibold text-lg mb-4 flex items-center gap-2">
              <CheckCircle2 className="w-5 h-5 text-primary" /> Key Takeaways
            </h3>
            <ul className="space-y-2">
              {lesson.takeaways.map((takeaway, idx) => (
                <li key={idx} className="flex gap-3">
                  <span className="text-primary font-bold">{idx + 1}.</span>
                  <span>{takeaway}</span>
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>
      )}

      <div className="pt-8 border-t">
        <Button 
          size="lg" 
          className="w-full sm:w-auto"
          onClick={handleComplete}
          disabled={completeMutation.isPending}
        >
          {lesson.completed ? "Back to Lessons" : "Mark as Completed"}
        </Button>
      </div>
    </div>
  );
}
