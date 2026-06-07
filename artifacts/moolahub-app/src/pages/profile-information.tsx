import { useEffect, useRef, useState } from "react";
import { Camera, AlertCircle, Check } from "lucide-react";
import { useLocation } from "wouter";
import { Card, Avatar, Button } from "@/components/ui";
import { PageHeader, BackLink } from "@/components/app/bits";
import {
  useGetProfile,
  useUpdateProfile,
  getGetProfileQueryKey,
  getGetMeQueryKey,
} from "@workspace/api-client-react";
import { useUpload } from "@workspace/object-storage-web";
import { useQueryClient } from "@tanstack/react-query";
import { avatarSrc, apiErrorMessage } from "@/lib/utils";

function Field({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <label className="block">
      <span className="text-sm font-medium text-foreground">{label}</span>
      {hint && <span className="ml-2 text-xs text-muted-foreground">{hint}</span>}
      <div className="mt-1.5">{children}</div>
    </label>
  );
}

const inputClass =
  "w-full rounded-xl border border-border bg-background px-3.5 py-2.5 text-sm text-foreground outline-none transition-colors placeholder:text-muted-foreground focus:border-jade-500/60 focus-ring";

export default function ProfileInformationPage() {
  const { data: profile, isLoading } = useGetProfile();
  const updateProfile = useUpdateProfile();
  const queryClient = useQueryClient();
  const [, setLocation] = useLocation();
  const fileInputRef = useRef<HTMLInputElement>(null);

  const [name, setName] = useState("");
  const [username, setUsername] = useState("");
  const [dateOfBirth, setDateOfBirth] = useState("");
  const [nationality, setNationality] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    if (profile) {
      setName(profile.name ?? "");
      setUsername(profile.username ?? "");
      setDateOfBirth(profile.dateOfBirth ?? "");
      setNationality(profile.nationality ?? "");
    }
  }, [profile]);

  const invalidate = () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: getGetProfileQueryKey() }),
      queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() }),
    ]);

  const { uploadFile, isUploading } = useUpload({
    onSuccess: async (res) => {
      try {
        await updateProfile.mutateAsync({ data: { avatarUrl: res.objectPath } });
        await invalidate();
      } catch (err) {
        setError(apiErrorMessage(err) ?? "Could not save profile picture.");
      }
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

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setSaved(false);
    const trimmedName = name.trim();
    if (!trimmedName) {
      setError("Name cannot be empty.");
      return;
    }
    try {
      await updateProfile.mutateAsync({
        data: {
          name: trimmedName,
          username: username.trim() || null,
          dateOfBirth: dateOfBirth || null,
          nationality: nationality.trim() || null,
        },
      });
      await invalidate();
      setSaved(true);
    } catch (err) {
      setError(apiErrorMessage(err) ?? "Could not update profile.");
    }
  };

  if (isLoading)
    return <div className="p-8 text-center text-muted-foreground">Loading…</div>;
  if (!profile) return null;

  return (
    <div className="mx-auto max-w-2xl space-y-6">
      <BackLink href="/profile" label="Account" />
      <PageHeader
        eyebrow="Profile"
        title="Profile information"
        description="Update how you appear across MoolaHub."
      />

      <Card className="p-6">
        <div className="flex items-center gap-4">
          <div className="relative">
            <Avatar
              name={profile.name}
              src={avatarSrc(profile.avatarUrl)}
              tone="jade"
              className="h-16 w-16 text-lg"
            />
            <button
              type="button"
              onClick={() => fileInputRef.current?.click()}
              disabled={isUploading}
              className="absolute -bottom-1 -right-1 flex h-7 w-7 items-center justify-center rounded-full border border-border bg-card text-foreground transition-colors hover:bg-accent focus-ring disabled:opacity-60"
              aria-label="Change profile picture"
            >
              <Camera className="h-3.5 w-3.5" />
            </button>
            <input
              ref={fileInputRef}
              type="file"
              accept="image/*"
              className="hidden"
              onChange={handleFile}
            />
          </div>
          <div>
            <p className="text-sm font-semibold text-foreground">Profile picture</p>
            <p className="text-xs text-muted-foreground">
              {isUploading ? "Uploading…" : "PNG or JPG, square works best."}
            </p>
          </div>
        </div>
      </Card>

      <Card className="p-6">
        <form onSubmit={handleSave} className="space-y-5">
          <Field label="Full name">
            <input
              className={inputClass}
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Your name"
            />
          </Field>
          <Field label="Username" hint="optional · unique">
            <input
              className={inputClass}
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              placeholder="username"
              autoCapitalize="none"
            />
          </Field>
          <Field label="Date of birth" hint="optional">
            <input
              type="date"
              className={inputClass}
              value={dateOfBirth}
              onChange={(e) => setDateOfBirth(e.target.value)}
            />
          </Field>
          <Field label="Nationality" hint="optional">
            <input
              className={inputClass}
              value={nationality}
              onChange={(e) => setNationality(e.target.value)}
              placeholder="e.g. Kenyan"
            />
          </Field>

          {error && (
            <p className="flex items-center gap-1.5 text-sm text-red-600 dark:text-red-400" role="alert">
              <AlertCircle className="h-4 w-4 shrink-0" /> {error}
            </p>
          )}
          {saved && (
            <p className="flex items-center gap-1.5 text-sm text-jade-600 dark:text-jade-400">
              <Check className="h-4 w-4 shrink-0" /> Saved.
            </p>
          )}

          <div className="flex gap-3">
            <Button type="submit" disabled={updateProfile.isPending}>
              {updateProfile.isPending ? "Saving…" : "Save changes"}
            </Button>
            <Button
              type="button"
              variant="ghost"
              onClick={() => setLocation("/profile")}
            >
              Cancel
            </Button>
          </div>
        </form>
      </Card>
    </div>
  );
}
