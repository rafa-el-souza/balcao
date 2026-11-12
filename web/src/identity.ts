// The public identity on the landing (design FR-25, §6.7), decided by the
// owner on 2026-11-04: every value is public by design. The e-mail link
// carries the prefilled subject.
export const AUTHOR_NAME = "Rafa Souza";
export const GITHUB_URL = "https://github.com/rafa-el-souza";
export const LINKEDIN_URL = "https://linkedin.com/in/rafa-el-souza";
export const EMAIL = "rafasouza.dev@pm.me";
export const EMAIL_SUBJECT = "Balcão: contato";
export const MAILTO = `mailto:${EMAIL}?subject=${encodeURIComponent(EMAIL_SUBJECT)}`;

// The project's documents, linked from "Como é feito".
export const REPOSITORY_URL = "https://github.com/rafa-el-souza/balcao";
export const DOCUMENTS = {
  design: `${REPOSITORY_URL}/blob/main/docs/design.md`,
  adrs: `${REPOSITORY_URL}/tree/main/docs/adr`,
  threats: `${REPOSITORY_URL}/blob/main/docs/threat-model.md`,
  evals: `${REPOSITORY_URL}/tree/main/evals`,
} as const;
