import { describe, expect, it } from "vitest";

import { resources } from "../i18n";
import { LOCALES } from "../locale";

// The CI check that the web app's locale files share the same keys (design
// NFR-09). The server's files have their own check in spec/i18n. A list (the
// stack's names) counts by its positions, so the three hold the same number
// of items. The locales are the ones the page loads, read from the i18n
// resources, so a language added there is held here too; and a key's
// placeholders, the {{values}} t() fills and the <tags> a Trans fills, are
// the same in every language, or the words of one would lose what the page
// puts in them (the owner's round at the MVP close, rows 1-FN-derive and
// 1-FN-placeholders).
type Tree = { [key: string]: string | string[] | Tree };

function leaves(tree: Tree | string[], prefix = ""): [string, string][] {
  return Object.entries(tree).flatMap(
    ([key, value]: [string, Tree[string]]) => {
      const path = prefix ? `${prefix}.${key}` : key;
      return typeof value === "string"
        ? [[path, value] as [string, string]]
        : leaves(value, path);
    },
  );
}

const locales: Record<string, Tree> = Object.fromEntries(
  Object.entries(resources).map(([locale, { translation }]) => [
    locale,
    translation as Tree,
  ]),
);

// A text's placeholders, sorted: each {{name}}, and each <tag> by its name.
function placeholders(text: string): string[] {
  return [
    ...text.matchAll(/\{\{\s*([^}\s,]+)[^}]*\}\}|<\/?([A-Za-z]+)\b[^>]*>/g),
  ]
    .map(([, value, tag]) => (value ? `{{${value}}}` : `<${tag ?? ""}>`))
    .sort();
}

// The keys whose placeholders differ from the first locale's, with the
// locale that differs.
function mismatched(trees: Record<string, Tree>): string[] {
  const [first, ...others] = Object.entries(trees);
  if (!first) return [];
  const reference = new Map(leaves(first[1]));
  return others.flatMap(([locale, tree]) =>
    leaves(tree)
      .filter(
        ([path, text]) =>
          reference.has(path) &&
          placeholders(text).join() !==
            placeholders(reference.get(path) ?? "").join(),
      )
      .map(([path]) => `${locale}:${path}`),
  );
}

describe("NFR-09 locale key parity (web)", () => {
  it("holds every locale the page loads, and only those", () => {
    expect(Object.keys(locales).sort()).toEqual([...LOCALES].sort());
  });

  it("has every key in every locale", () => {
    const keysOf = (tree: Tree) => leaves(tree).map(([path]) => path);
    const allKeys = new Set(Object.values(locales).flatMap(keysOf));
    const missing = Object.fromEntries(
      Object.entries(locales)
        .map(([locale, tree]) => {
          const own = new Set(keysOf(tree));
          return [
            locale,
            [...allKeys].filter((key) => !own.has(key)).sort(),
          ] as const;
        })
        .filter(([, keys]) => keys.length > 0),
    );
    expect(missing).toEqual({});
  });

  it("gives each key the same placeholders in every locale", () => {
    expect(mismatched(locales)).toEqual([]);
  });

  it("finds a placeholder one locale left out, or a tag it renamed", () => {
    expect(
      placeholders("Conversa <token>{{token}}</token>, {{count}}"),
    ).toEqual(["<token>", "<token>", "{{count}}", "{{token}}"]);
    expect(
      mismatched({
        "pt-BR": { a: "{{count}} eventos", b: "<email>{{email}}</email>" },
        en: { a: "events", b: "<mail>{{email}}</mail>" },
        es: { a: "{{count}} eventos", b: "<email>{{email}}</email>" },
      }),
    ).toEqual(["en:a", "en:b"]);
  });

  // Review finding C6 of pull request #29: the money's symbols are words of
  // the locale files, the same three languages draw them alike (docs/
  // prototype/chat-en.html, chat-es.html), joined to the figure by a no-break
  // space (the owner's round at the MVP close, row 35-nbsp).
  it("writes each currency's symbol around its figure, in every locale", () => {
    for (const [locale, tree] of Object.entries(locales)) {
      const money = (tree.instrument as Tree).money as Tree;
      expect(money, locale).toEqual({
        usd: "US$\u00a0{{value}}",
        brl: "R$\u00a0{{value}}",
      });
    }
  });

  it("has no empty string in any locale", () => {
    const empty = Object.entries(locales).flatMap(([locale, tree]) =>
      leaves(tree)
        .filter(([, value]) => value.trim() === "")
        .map(([path]) => `${locale}:${path}`),
    );
    expect(empty).toEqual([]);
  });
});
