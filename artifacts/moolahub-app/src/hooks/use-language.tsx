import { useCallback, useEffect, useMemo, useState } from "react";
import { I18nextProvider } from "react-i18next";
import i18n from "@/i18n";
import {
  LANGUAGES,
  STORAGE_KEY,
  getLanguageDef,
  readStoredLanguage,
  type LanguageCode,
} from "@/i18n/languages";
import { LanguageContext, type LanguageContextValue } from "@/hooks/language-context";

function applyDocumentLanguage(code: LanguageCode) {
  const def = getLanguageDef(code);
  const root = document.documentElement;
  root.setAttribute("lang", def.code);
  root.setAttribute("dir", def.dir);
}

export function LanguageProvider({ children }: { children: React.ReactNode }) {
  const [language, setLanguageState] = useState<LanguageCode>(readStoredLanguage);

  useEffect(() => {
    if (i18n.language !== language) void i18n.changeLanguage(language);
    applyDocumentLanguage(language);
  }, [language]);

  const setLanguage = useCallback((code: LanguageCode) => {
    setLanguageState(code);
    try {
      window.localStorage.setItem(STORAGE_KEY, code);
    } catch {
      /* storage may be unavailable (private mode) */
    }
  }, []);

  const value = useMemo<LanguageContextValue>(
    () => ({
      language,
      dir: getLanguageDef(language).dir,
      languages: LANGUAGES,
      setLanguage,
    }),
    [language, setLanguage],
  );

  return (
    <I18nextProvider i18n={i18n}>
      <LanguageContext.Provider value={value}>{children}</LanguageContext.Provider>
    </I18nextProvider>
  );
}
