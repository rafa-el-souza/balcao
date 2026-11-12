import { useEffect } from "react";
import { useTranslation } from "react-i18next";

import {
  AUTHOR_NAME,
  DOCUMENTS,
  GITHUB_URL,
  LINKEDIN_URL,
  MAILTO,
} from "../identity";
import openers from "../openers.json";
import { cx } from "../ui/cx";
import { Cross, Icon } from "../ui/Icon";
import { LanguageSwitch } from "../ui/LanguageSwitch";
import parts from "../ui/parts.module.css";
import styles from "./Landing.module.css";

// The landing, `/` (design §6.7, §6.8; docs/prototype/landing.html). The
// drawing is the target; a line whose source arrives later is left out until
// then, not shown as a promise: the live numbers and the status link (FR-13,
// M3), the WhatsApp QR (day 12), the example conversations (FR-22, M5), the
// offer's tags and exclusions (FR-25, M5), the scorecard's rows (the first
// scorecard, PR-14), the booking line (FR-08, M2), voice notes (FR-11, M4)
// and the privacy link (PR-17). Other companies' marks wait for their
// owners' files or permission.

// The opener's language, as the page's lang attribute names it.
const LANG = { pt: "pt-BR", en: "en", es: "es" } as const;

const DOCUMENT_LINKS = ["design", "adrs", "threats", "evals"] as const;

export function Landing() {
  const { t } = useTranslation();

  useEffect(() => {
    document.title = t("landing.title");
  }, [t]);

  return (
    <div className={styles.landing}>
      <header className={cx(parts.letterhead, styles.masthead)}>
        <a className={parts.wordmark} href="/">
          <Cross />
          {t("app.name")}
        </a>
        <span className={styles.pharmacy}>{t("app.pharmacy")}</span>
        <LanguageSwitch className={styles.langs} />
      </header>

      <main className={styles.main}>
        <section className={styles.hero} aria-labelledby="headline">
          <div className={styles.pitch}>
            <h1 id="headline">{t("landing.headline")}</h1>
            <p className={styles.lede}>{t("landing.lede")}</p>
          </div>

          <div className={styles.say}>
            <p className={styles.sayLabel} id="say-label">
              {t("landing.say")}
            </p>
            <ul className={parts.chips} aria-labelledby="say-label">
              {Object.entries(openers).map(([key, opener]) => (
                <li key={key}>
                  <a
                    className={parts.chip}
                    href={`/chat?say=${key}`}
                    lang={LANG[opener.lang as keyof typeof LANG]}
                  >
                    {opener.text}
                  </a>
                </li>
              ))}
            </ul>
          </div>
        </section>

        <section className={styles.does} aria-labelledby="does-title">
          <h2 id="does-title">{t("landing.does.title")}</h2>
          <ul>
            <li>
              <Icon name="tag" /> <span>{t("landing.does.stock")}</span>
            </li>
            <li>
              <Icon name="clinical" /> <span>{t("landing.does.clinical")}</span>
            </li>
            <li>
              <Icon name="speech" /> <span>{t("landing.does.languages")}</span>
            </li>
          </ul>
        </section>

        <section className={styles.business} aria-labelledby="business-title">
          <h2 id="business-title">{t("landing.business.title")}</h2>
          <p>
            <strong>{t("landing.business.knows")}</strong>{" "}
            {t("landing.business.pharmacist")}
          </p>
          <p className={styles.contact}>
            <a className={parts.action} href={MAILTO}>
              <Icon name="envelope" /> {t("landing.business.email")}
            </a>
          </p>
        </section>

        <section
          className={cx(parts.slip, styles.built)}
          aria-labelledby="built-title"
        >
          <h2 className={parts.slipTitle} id="built-title">
            {t("landing.built.title")}
          </h2>
          <ul className={styles.stack}>
            {t("landing.built.stack", { returnObjects: true }).map((item) => (
              <li key={item}>{item}</li>
            ))}
          </ul>
          <ul className={styles.documents}>
            {DOCUMENT_LINKS.map((name) => (
              <li key={name}>
                <a className={parts.doc} href={DOCUMENTS[name]}>
                  {t(`landing.built.${name}`)} <Icon name="out" />
                </a>
              </li>
            ))}
          </ul>
        </section>
      </main>

      <footer className={styles.colophon}>
        <p className={cx(parts.stamp, styles.warning)}>
          <strong>{t("landing.warning.label")}</strong>{" "}
          {t("landing.warning.text")}
        </p>
        <div className={styles.signature}>
          <p className={styles.signedName}>
            <span className={styles.signedBy}>{t("landing.signature.by")}</span>{" "}
            <span className={styles.signedHand}>{AUTHOR_NAME}</span>
          </p>
          <p className={styles.signedLinks}>
            <a className={parts.doc} href={GITHUB_URL}>
              {t("landing.signature.github")}
            </a>{" "}
            <a className={parts.doc} href={LINKEDIN_URL}>
              {t("landing.signature.linkedin")}
            </a>{" "}
            <a className={parts.doc} href={MAILTO}>
              {t("landing.signature.email")}
            </a>
          </p>
        </div>
      </footer>
    </div>
  );
}
