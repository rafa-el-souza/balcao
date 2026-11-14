import { useTranslation } from "react-i18next";

import { cx } from "./cx";
import { Cross } from "./Icon";
import { LanguageSwitch } from "./LanguageSwitch";
import styles from "./PageMasthead.module.css";
import parts from "./parts.module.css";

// The letterhead of a page that is not the landing (the trace page, the
// privacy page; docs/prototype/trace.html, privacy.html): the wordmark, which
// leads home, the page's name in italic and the language switch. The status
// link joins with the status page (M3).
export function PageMasthead({ name }: { name: string }) {
  const { t } = useTranslation();
  return (
    <header className={cx(parts.letterhead, styles.masthead)}>
      <a className={parts.wordmark} href="/">
        <Cross />
        {t("app.name")}
      </a>
      <span className={styles.pageName}>{name}</span>
      <LanguageSwitch className={styles.langs} />
    </header>
  );
}
