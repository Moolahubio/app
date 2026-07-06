import { createContext, useContext } from "react";
import type { LanguageCode, LanguageDef } from "@/i18n/languages";

export interface LanguageContextValue {
  language: LanguageCode;
  dir: "ltr" | "rtl";
  languages: LanguageDef[];
  /** Apply a language locally (state + i18next + <html> + localStorage). Does NOT
   *  persist to the server — that is done explicitly on user actions via
   *  `useLanguageSetting`, so hydrating from the server can reuse this safely. */
  setLanguage: (code: LanguageCode) => void;
}

/**
 * Context lives in its own module — with no runtime dependency on `@/i18n` — so
 * that editing locale resources (or any HMR cascade through i18n) can never
 * re-run `createContext` and hand consumers a fresh, mismatched instance.
 */
export const LanguageContext = createContext<LanguageContextValue | null>(null);

export function useLanguage(): LanguageContextValue {
  const ctx = useContext(LanguageContext);
  if (!ctx) throw new Error("useLanguage must be used within a LanguageProvider");
  return ctx;
}
