// @vitest-environment node
import { describe, expect, it } from "vitest";

import { errorsCiting } from "./lint";

// Review finding C1 on pull request #1: the rule caught only bare JSX text and
// a bare string on four attributes. A string constant declared outside JSX (in
// a .ts or .tsx file) is out of lint's reach, and no check runs on it per pull
// request: only item 2 of docs/reviews/interface-checklist.md asks for a grep
// of web/src, at the MVP and milestone closes (finding V3, pull request #1).
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
      [
        "a concatenation",
        'export const A = ({ name }: { name: string }) => <p>{"Olá, " + name}</p>;',
      ],
      [
        "a nested conditional",
        'export const A = ({ s }: { s: number }) => <p>{s > 0 ? (s > 1 ? "Muitos" : "Um") : null}</p>;',
      ],
      [
        "a chained conditional",
        'export const A = ({ s }: { s: number }) => <p>{s > 1 ? s : s > 0 ? "Um" : "Nenhum"}</p>;',
      ],
      [
        "an inline list",
        'export const A = () => <ul>{["Tem dipirona?", "Horários"].map((c) => <li key={c}>{c}</li>)}</ul>;',
      ],
      [
        "a meta content",
        'export const A = () => <meta name="description" content="Farmácia de plantão" />;',
      ],
      [
        "a component's content",
        'const Tip = (p: { content: string }) => <span>{p.content}</span>;\nexport const A = () => <Tip content="Ver horários" />;',
      ],
      [
        "a camelCase aria prop",
        'const Close = (p: { ariaLabel: string }) => <button type="button" aria-label={p.ariaLabel} />;\nexport const A = () => <Close ariaLabel="Fechar" />;',
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
      [
        "a hidden value",
        'export const A = () => <input type="hidden" name="locale" value="pt-BR" />;',
      ],
      [
        "a submit button's value",
        'export const A = () => <button type="submit" name="intent" value="cancel">×</button>;',
      ],
      [
        "an option's value",
        'export const A = () => <select aria-labelledby="l"><option value="es">{null}</option></select>;',
      ],
      [
        "a key built from the translation",
        'import { useTranslation } from "react-i18next";\nexport const A = ({ ok }: { ok: boolean }) => { const { t } = useTranslation(); return <p>{t(ok ? "app.name" : "app.placeholder")}</p>; };',
      ],
    ])("accepts %s", async (_form, code) => {
      expect(await errorsCiting(code, "NFR-09")).toEqual([]);
    });
  },
);
