import { useTranslation } from "react-i18next";

import { LOCALES, type Locale, persistLocale } from "../locale";
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
