import { describe, expect, it } from "vitest";

import en from "./en.json";
import es from "./es.json";
import ptBR from "./pt-BR.json";

// The CI check that the web app's three locale files share the same keys
// (design NFR-09). The server's files have their own check in spec/i18n.
// A list (the stack's names) counts by its positions, so the three hold the
// same number of items.
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

const locales: Record<string, Tree> = { "pt-BR": ptBR, en, es };

describe("NFR-09 locale key parity (web)", () => {
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

  it("has no empty string in any locale", () => {
    const empty = Object.entries(locales).flatMap(([locale, tree]) =>
      leaves(tree)
        .filter(([, value]) => value.trim() === "")
        .map(([path]) => `${locale}:${path}`),
    );
    expect(empty).toEqual([]);
  });
});
