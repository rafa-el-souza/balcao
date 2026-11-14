import { useTranslation } from "react-i18next";

import { AUTHOR_NAME, GITHUB_URL, LINKEDIN_URL, MAILTO } from "../identity";
import { cx } from "./cx";
import parts from "./parts.module.css";
import styles from "./Signature.module.css";

// The signature that closes the landing and the privacy page (design §6.7,
// FR-25; docs/prototype/landing.html, privacy.html), as a prescription is
// signed: the author's name in a pen hand on the signature rule, and under it
// the ways to reach him. No photo. Each page places it.
export function Signature({ className }: { className?: string | undefined }) {
  const { t } = useTranslation();
  return (
    <div className={cx(styles.signature, className)}>
      <p className={styles.signedName}>
        <span className={styles.signedBy}>{t("signature.by")}</span>{" "}
        <span className={styles.signedHand}>{AUTHOR_NAME}</span>
      </p>
      <p className={styles.signedLinks}>
        <a className={parts.doc} href={GITHUB_URL}>
          {t("signature.github")}
        </a>{" "}
        <a className={parts.doc} href={LINKEDIN_URL}>
          {t("signature.linkedin")}
        </a>{" "}
        <a className={parts.doc} href={MAILTO}>
          {t("signature.email")}
        </a>
      </p>
    </div>
  );
}
