import { useCallback } from "react";
import { useQueryClient } from "@tanstack/react-query";
import {
  useUpdateProfile,
  getGetMeQueryKey,
  getGetProfileQueryKey,
} from "@workspace/api-client-react";
import { useLanguage } from "@/hooks/language-context";
import type { LanguageCode } from "@/i18n/languages";

/**
 * User-facing language switching: applies the choice instantly (local) and
 * persists it to the account. Used by the language settings page (and any other
 * user-initiated switcher). Server hydration on login uses the dumb
 * `useLanguage().setLanguage` instead, so it never triggers a PATCH.
 */
export function useLanguageSetting() {
  const { language, dir, languages, setLanguage } = useLanguage();
  const updateProfile = useUpdateProfile();
  const queryClient = useQueryClient();

  const changeLanguage = useCallback(
    async (code: LanguageCode) => {
      setLanguage(code);
      await updateProfile.mutateAsync({ data: { language: code } });
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: getGetMeQueryKey() }),
        queryClient.invalidateQueries({ queryKey: getGetProfileQueryKey() }),
      ]);
    },
    [setLanguage, updateProfile, queryClient],
  );

  return { language, dir, languages, changeLanguage, isSaving: updateProfile.isPending };
}
