import { useRef, useState } from "react";
import { ImagePlus, Loader2, X } from "lucide-react";
import { useUpload } from "@workspace/object-storage-web";
import { Label } from "@/components/ui/label";
import { avatarSrc, cn } from "@/lib/utils";

type ImageUploadFieldProps = {
  label: string;
  hint?: string;
  value: string | null;
  onChange: (objectPath: string | null) => void;
  disabled?: boolean;
};

/** Cover-image picker that mirrors the avatar upload flow: presigned PUT to
 * object storage, then stores the returned objectPath on the parent form. */
export function ImageUploadField({ label, hint, value, onChange, disabled }: ImageUploadFieldProps) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [error, setError] = useState<string | null>(null);

  const { uploadFile, isUploading } = useUpload({
    onSuccess: (res) => {
      setError(null);
      onChange(res.objectPath);
    },
    onError: () => setError("Could not upload image."),
  });

  const handleFile = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;
    if (!file.type.startsWith("image/")) {
      setError("Please choose an image file.");
      return;
    }
    setError(null);
    void uploadFile(file);
  };

  const preview = avatarSrc(value);
  const busy = isUploading || disabled;

  return (
    <div className="space-y-2">
      <Label>{label}</Label>
      <div className="flex items-center gap-3">
        <button
          type="button"
          onClick={() => inputRef.current?.click()}
          disabled={busy}
          className={cn(
            "relative flex h-20 w-20 shrink-0 items-center justify-center overflow-hidden rounded-2xl border-2 border-dashed border-border bg-muted text-muted-foreground transition-colors hover:border-jade-500/40 hover:text-jade-600 dark:hover:text-jade-300 focus-ring disabled:opacity-60",
            preview && "border-solid border-border",
          )}
          aria-label={preview ? "Change picture" : "Upload a picture"}
        >
          {isUploading ? (
            <Loader2 className="h-5 w-5 animate-spin" />
          ) : preview ? (
            <img src={preview} alt="" className="h-full w-full object-cover" />
          ) : (
            <ImagePlus className="h-6 w-6" />
          )}
        </button>
        <div className="min-w-0 flex-1">
          <p className="text-xs text-muted-foreground">
            {hint ?? "Add a photo to keep the dream alive."}
          </p>
          {value && !isUploading && (
            <button
              type="button"
              onClick={() => onChange(null)}
              className="mt-1 inline-flex items-center gap-1 text-xs font-medium text-muted-foreground hover:text-foreground"
            >
              <X className="h-3 w-3" /> Remove
            </button>
          )}
        </div>
      </div>
      {error && <p className="text-xs text-red-600 dark:text-red-400">{error}</p>}
      <input
        ref={inputRef}
        type="file"
        accept="image/*"
        className="hidden"
        onChange={handleFile}
      />
    </div>
  );
}
