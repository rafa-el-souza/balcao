// @vitest-environment node
import { describe, expect, it } from "vitest";

import { errorsCiting } from "./lint";

// Review finding C1 on pull request #1: the rule caught only bare JSX text and
// a bare string on four attributes. A string constant in a .ts file is out of
// lint's reach; the interface review's grep of web/src covers it.
describe(
  "NFR-09 lint keeps user-facing text in the locale files",
  { timeout: 30_000 },
  () => {
    it.each([
      ["JSX text", "export const A = () => <p>Em construção.</p>;"],
      [
        "a string in braces",
        'export const A = () => <p>{"Em construção."}</p>;',
      ],
      [
        "a template literal in braces",
        "export const A = () => <p>{`Em construção.`}</p>;",
      ],
      [
        "a conditional",
        'export const A = ({ ok }: { ok: boolean }) => <p>{ok ? "Sim" : "Não"}</p>;',
      ],
      [
        "a title in braces",
        'export const A = () => <p title={"Ver horários"} />;',
      ],
      ["a title", 'export const A = () => <p title="Ver horários" />;'],
      [
        "a submit value",
        'export const A = () => <input type="submit" readOnly value="Enviar" />;',
      ],
      [
        "an aria-description",
        'export const A = () => <div aria-description="Pedido enviado" />;',
      ],
      [
        "a component's label",
        'const Chip = (p: { label: string }) => <span>{p.label}</span>;\nexport const A = () => <Chip label="Ver horários" />;',
      ],
    ])("rejects %s", async (_form, code) => {
      expect(await errorsCiting(code, "NFR-09")).not.toEqual([]);
    });

    it.each([
      [
        "text from t()",
        'import { useTranslation } from "react-i18next";\nexport const A = () => { const { t } = useTranslation(); return <p title={t("app.name")}>{t("app.placeholder")}</p>; };',
      ],
      [
        "a decorative image",
        'export const A = () => <img src="/d.svg" alt="" />;',
      ],
      ["a glyph", 'export const A = () => <button type="button">×</button>;'],
      [
        "a route and a type",
        'export const A = () => <a href="/chat" type="text/html" lang="pt-BR" />;',
      ],
    ])("accepts %s", async (_form, code) => {
      expect(await errorsCiting(code, "NFR-09")).toEqual([]);
    });
  },
);
