import { type ReactNode, useEffect } from "react";
import { Trans, useTranslation } from "react-i18next";

import { AUTHOR_NAME, EMAIL, MAILTO } from "../identity";
import { cx } from "../ui/cx";
import { PageMasthead } from "../ui/PageMasthead";
import parts from "../ui/parts.module.css";
import { Signature } from "../ui/Signature";
import styles from "./Privacy.module.css";

// The privacy page, `/privacy` (design §6.7; docs/prototype/privacy.html),
// one column of text in the counter's voice. It is also the Telegram bot's
// own privacy policy, the URL set in BotFather: Telegram's standard policy
// would forbid sending a message to the model (ADR-0016), and its terms ask a
// policy to say what is kept, how and what for (FR-19). So it reads alone,
// and every kept item says what it is for. The drawing is the target; a line
// whose source arrives later is left out until then: the backups (M3, design
// §8), Cloudflare's check (the Turnstile slice, FR-18) and the status link
// (M3).

const KEPT = [
  "messages",
  "reservations",
  "record",
  "web",
  "telegram",
  "ip",
] as const;

function Section({
  name,
  title,
  children,
}: {
  name: string;
  title: string;
  children: ReactNode;
}) {
  return (
    <section aria-labelledby={name}>
      <h2 id={name}>{title}</h2>
      {children}
    </section>
  );
}

export function Privacy() {
  const { t } = useTranslation();

  useEffect(() => {
    document.title = t("privacy.title");
  }, [t]);

  return (
    <div className={styles.page}>
      <PageMasthead name={t("privacy.pageName")} />

      <main className={styles.prose}>
        <h1>{t("privacy.heading")}</h1>
        <p>{t("privacy.what")}</p>
        <p className={cx(parts.stamp, styles.advice)}>
          <strong>{t("privacy.advice.label")}</strong>{" "}
          {t("privacy.advice.text")}
        </p>

        <Section name="kept" title={t("privacy.kept.title")}>
          <ul>
            {KEPT.map((item) => (
              <li key={item}>{t(`privacy.kept.${item}`)}</li>
            ))}
          </ul>
        </Section>

        <Section name="agreement" title={t("privacy.agreement.title")}>
          <p>
            <Trans
              i18nKey="privacy.agreement.text"
              components={{ strong: <strong /> }}
            />
          </p>
        </Section>

        <Section name="retention" title={t("privacy.retention.title")}>
          <p>{t("privacy.retention.intro")}</p>
          <ul>
            {t("privacy.retention.items", { returnObjects: true }).map(
              (item) => (
                <li key={item}>{item}</li>
              ),
            )}
          </ul>
          <p>{t("privacy.retention.logs")}</p>
          <p>{t("privacy.retention.counters")}</p>
          <p>{t("privacy.retention.totals")}</p>
        </Section>

        <Section name="deletion" title={t("privacy.deletion.title")}>
          <p>
            <Trans
              i18nKey="privacy.deletion.text"
              components={{ cmd: <code /> }}
            />
          </p>
          <p>{t("privacy.deletion.telegram")}</p>
        </Section>

        <Section name="readers" title={t("privacy.readers.title")}>
          <p>{t("privacy.readers.trace")}</p>
          <p>{t("privacy.readers.cases")}</p>
        </Section>

        <Section name="processors" title={t("privacy.processors.title")}>
          <ul>
            {t("privacy.processors.items", { returnObjects: true }).map(
              (item) => (
                <li key={item}>{item}</li>
              ),
            )}
          </ul>
        </Section>

        <Section name="contact" title={t("privacy.contact.title")}>
          <p>
            <Trans
              i18nKey="privacy.contact.text"
              values={{ name: AUTHOR_NAME, email: EMAIL }}
              components={{ email: <a href={MAILTO}>{EMAIL}</a> }}
            />
          </p>
        </Section>
      </main>

      <footer className={styles.colophon}>
        <Signature />
      </footer>
    </div>
  );
}
