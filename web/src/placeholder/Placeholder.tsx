import { useTranslation } from "react-i18next";

import { LOCALES, type Locale } from "../i18n";
import styles from "./Placeholder.module.css";

// The page the domain shows until the landing ships (design §9.1, PR-10):
// the same short text in the three languages at once (NFR-09), each section
// marked with its language for screen readers and hyphenation.
export const REPOSITORY_URL = "https://github.com/rafa-el-souza/balcao";

function LanguageSection({ locale }: { locale: Locale }) {
  const { t } = useTranslation("translation", { lng: locale });
  const headingId = `placeholder-${locale}`;

  return (
    <section
      lang={locale}
      aria-labelledby={headingId}
      className={styles.section}
    >
      <p className={styles.status}>{t("placeholder.status")}</p>
      <h2 id={headingId} className={styles.tagline}>
        {t("placeholder.tagline")}
      </h2>
      <p>{t("placeholder.soon")}</p>
      <p>
        {t("placeholder.meanwhile")}{" "}
        <a href={REPOSITORY_URL}>{t("placeholder.repository")}</a>
      </p>
    </section>
  );
}

export function Placeholder() {
  const { t } = useTranslation();

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <h1 className={styles.brand}>{t("app.name")}</h1>
        <p className={styles.pharmacy}>{t("app.pharmacy")}</p>
      </header>
      <main className={styles.sections}>
        {LOCALES.map((locale) => (
          <LanguageSection key={locale} locale={locale} />
        ))}
      </main>
    </div>
  );
}
