/**
 * Supported UI languages for MoolaHub's platform-wide i18n.
 *
 * `code`       — app language code (also the i18next language key + <html lang>).
 * `label`      — English name (for reference / accessibility).
 * `nativeName` — endonym shown in the language picker.
 * `dir`        — text direction; Arabic is right-to-left.
 * `locale`     — BCP-47 locale used for Intl number/date formatting.
 */
export type LanguageCode = "en" | "ar" | "fr" | "sw" | "pcm" | "ha" | "zh";

export interface LanguageDef {
  code: LanguageCode;
  label: string;
  nativeName: string;
  dir: "ltr" | "rtl";
  locale: string;
}

export const LANGUAGES: LanguageDef[] = [
  { code: "en", label: "English", nativeName: "English", dir: "ltr", locale: "en" },
  { code: "ar", label: "Arabic", nativeName: "العربية", dir: "rtl", locale: "ar" },
  { code: "fr", label: "French", nativeName: "Français", dir: "ltr", locale: "fr" },
  { code: "sw", label: "Swahili", nativeName: "Kiswahili", dir: "ltr", locale: "sw" },
  { code: "pcm", label: "Nigerian Pidgin", nativeName: "Naijá", dir: "ltr", locale: "en-NG" },
  { code: "ha", label: "Hausa", nativeName: "Hausa", dir: "ltr", locale: "ha" },
  { code: "zh", label: "Mandarin", nativeName: "中文", dir: "ltr", locale: "zh-CN" },
];

export const DEFAULT_LANGUAGE: LanguageCode = "en";
export const STORAGE_KEY = "moolahub-language";

const BY_CODE: Record<string, LanguageDef> = Object.fromEntries(
  LANGUAGES.map((l) => [l.code, l]),
);

export function isLanguageCode(value: unknown): value is LanguageCode {
  return typeof value === "string" && value in BY_CODE;
}

export function getLanguageDef(code: string | null | undefined): LanguageDef {
  return (code != null && BY_CODE[code]) || BY_CODE[DEFAULT_LANGUAGE];
}

/** BCP-47 locale for Intl formatting, resolved from an app language code. */
export function localeFor(code: string | null | undefined): string {
  return getLanguageDef(code).locale;
}

/** Text direction for a given app language code. */
export function dirFor(code: string | null | undefined): "ltr" | "rtl" {
  return getLanguageDef(code).dir;
}

/** Read the persisted language for guests / first paint. Never throws. */
export function readStoredLanguage(): LanguageCode {
  if (typeof window === "undefined") return DEFAULT_LANGUAGE;
  try {
    const stored = window.localStorage.getItem(STORAGE_KEY);
    if (isLanguageCode(stored)) return stored;
  } catch {
    /* storage may be unavailable (private mode) */
  }
  return DEFAULT_LANGUAGE;
}
