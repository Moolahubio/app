import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
} from "react";
import { I18nextProvider } from "react-i18next";
import i18n from "@/i18n";
import {
  LANGUAGES,
  STORAGE_KEY,
  getLanguageDef,
  readStoredLanguage,
  type LanguageCode,
  type LanguageDef,
} from "@/i18n/languages";

interface LanguageContextValue {
  language: LanguageCode;
  dir: "ltr" | "rtl";
  languages: LanguageDef[];
  /** Apply a language locally (state + i18next + <html> + localStorage). Does NOT
   *  persist to the server — that is done explicitly on user actions via
   *  `useLanguageSetting`, so hydrating from the server can reuse this safely. */
  setLanguage: (code: LanguageCode) => void;
}

const LanguageContext = createContext<LanguageContextValue | null>(null);

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

export function useLanguage(): LanguageContextValue {
  const ctx = useContext(LanguageContext);
  if (!ctx) throw new Error("useLanguage must be used within a LanguageProvider");
  return ctx;
}
