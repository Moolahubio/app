import i18n from "i18next";
import { initReactI18next } from "react-i18next";
import { DEFAULT_LANGUAGE, readStoredLanguage } from "./languages";

/**
 * Translation resources are auto-discovered from `locales/<lng>/<ns>.json`.
 * Adding a new namespace file for a language is enough for it to be bundled and
 * registered — no manual wiring here. Keeps per-feature translation work (which
 * we parallelise across namespaces) fully additive.
 */
const modules = import.meta.glob("./locales/**/*.json", { eager: true }) as Record<
  string,
  { default: Record<string, unknown> }
>;

const resources: Record<string, Record<string, Record<string, unknown>>> = {};
const namespaces = new Set<string>(["common"]);

for (const [path, mod] of Object.entries(modules)) {
  const match = path.match(/\.\/locales\/([^/]+)\/(.+)\.json$/);
  if (!match) continue;
  const [, lng, ns] = match;
  namespaces.add(ns);
  (resources[lng] ??= {})[ns] = mod.default;
}

void i18n.use(initReactI18next).init({
  resources,
  lng: readStoredLanguage(),
  fallbackLng: DEFAULT_LANGUAGE,
  ns: Array.from(namespaces),
  defaultNS: "common",
  fallbackNS: "common",
  interpolation: { escapeValue: false },
  returnNull: false,
  react: { useSuspense: false },
});

export default i18n;
