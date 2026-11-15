import { useEffect } from "react";
import { useTranslation } from "react-i18next";

import {
  LOCALES,
  type Locale,
  persistLocale,
  readLocaleCookie,
} from "../locale";
import { cx } from "./cx";
import styles from "./LanguageSwitch.module.css";
import parts from "./parts.module.css";

// The visible switcher of NFR-09, in the header of every page. The choice
// persists (a cookie the server reads too) and takes effect at once. Each
// language is a button that keeps the focus; the current one says so. Its
// name begins with the code it shows (WCAG 2.5.3) and goes on with the
// language's own name, in that language.
export function LanguageSwitch({
  variant = "counter",
  className,
  onSwitch,
}: {
  variant?: "counter" | "instrument";
  className?: string | undefined;
  onSwitch?: (locale: Locale) => void;
}) {
  const { t, i18n } = useTranslation();
  const current = i18n.language;

  const choose = (locale: Locale) => {
    if (locale === current) return;
    persistLocale(locale);
    void i18n.changeLanguage(locale);
    onSwitch?.(locale);
  };

  // A page the browser restores from its back-forward cache keeps the
  // language it had, though the visitor may have chosen another on a later
  // page: the cookie holds the choice, and the page takes it as a press
  // would. Every page has a switch, so every page listens; a second switch
  // on the page finds the language already taken (the owner's round at the
  // MVP close, row 14-FN-bfcache).
  useEffect(() => {
    const restored = (event: PageTransitionEvent) => {
      if (!event.persisted) return;
      const chosen = readLocaleCookie(document.cookie);
      if (chosen === null || chosen === i18n.language) return;
      document.documentElement.lang = chosen;
      void i18n.changeLanguage(chosen);
      onSwitch?.(chosen);
    };
    window.addEventListener("pageshow", restored);
    return () => {
      window.removeEventListener("pageshow", restored);
    };
  }, [i18n, onSwitch]);

  return (
    <nav
      className={cx(styles.langs, styles[variant], className)}
      aria-label={t("language.label")}
    >
      {LOCALES.map((locale) => (
        <button
          key={locale}
          type="button"
          className={styles.lang}
          lang={locale}
          aria-current={locale === current ? "true" : undefined}
          onClick={() => {
            choose(locale);
          }}
        >
          {locale.slice(0, 2).toUpperCase()}{" "}
          <span className={parts.visuallyHidden}>
            {t(`language.${locale}`)}
          </span>
        </button>
      ))}
    </nav>
  );
}
