import "i18next";

import type ptBR from "./locales/pt-BR.json";

// Type-checks every t() key against the pt-BR file (design NFR-09).
declare module "i18next" {
  interface CustomTypeOptions {
    defaultNS: "translation";
    resources: { translation: typeof ptBR };
  }
}
