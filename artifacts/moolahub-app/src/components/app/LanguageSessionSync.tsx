import { useEffect, useRef } from "react";
import { useAuth } from "@/hooks/use-auth";
import { useLanguage } from "@/hooks/use-language";
import { isLanguageCode } from "@/i18n/languages";

/**
 * Hydrates the UI language from the signed-in account's saved preference.
 * Rendered inside AuthProvider (mirrors WalletSessionSync). Only reacts to
 * *changes* in the server value, so it never fights a user's in-session switch
 * (which persists via useLanguageSetting and refetches the same value). Applies
 * locally only — never issues a PATCH.
 */
export function LanguageSessionSync() {
  const { user } = useAuth();
  const { language, setLanguage } = useLanguage();
  const lastServer = useRef<string | null>(null);

  useEffect(() => {
    const serverLang = user?.language;
    if (!isLanguageCode(serverLang)) return;
    if (serverLang === lastServer.current) return;
    lastServer.current = serverLang;
    if (serverLang !== language) setLanguage(serverLang);
  }, [user?.language, language, setLanguage]);

  return null;
}
