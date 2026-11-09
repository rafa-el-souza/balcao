// @vitest-environment node
import { describe, expect, it } from "vitest";

import { errorsCiting } from "./lint";

// Review findings C2 and C5 on pull request #1: the ban matched only the JSX
// attribute spelling, and shared its rule id with the NFR-09 entries.
describe("SR-03 lint forbids HTML from strings", { timeout: 30_000 }, () => {
  it.each([
    [
      "the JSX attribute",
      "export const A = ({ h }: { h: string }) => <div dangerouslySetInnerHTML={{ __html: h }} />;",
    ],
    [
      "a spread",
      "export const A = ({ h }: { h: string }) => <div {...{ dangerouslySetInnerHTML: { __html: h } }} />;",
    ],
    [
      "createElement props",
      'import { createElement } from "react"; export const A = ({ h }: { h: string }) => createElement("div", { dangerouslySetInnerHTML: { __html: h } });',
    ],
    [
      "innerHTML",
      "export function put(el: HTMLElement, h: string) { el.innerHTML = h; }",
    ],
    [
      "outerHTML",
      "export function put(el: HTMLElement, h: string) { el.outerHTML = h; }",
    ],
    [
      "insertAdjacentHTML",
      'export function put(el: HTMLElement, h: string) { el.insertAdjacentHTML("beforeend", h); }',
    ],
    [
      "srcDoc",
      "export const A = ({ h, n }: { h: string; n: string }) => <iframe title={n} srcDoc={h} />;",
    ],
    [
      "srcDoc through a spread",
      "export const A = ({ h, n }: { h: string; n: string }) => <iframe title={n} {...{ srcDoc: h }} />;",
    ],
    [
      "srcDoc through createElement",
      'import { createElement } from "react"; export const A = ({ h, n }: { h: string; n: string }) => createElement("iframe", { title: n, srcDoc: h });',
    ],
  ])("rejects %s", async (_form, code) => {
    expect(await errorsCiting(code, "SR-03")).not.toEqual([]);
  });

  it("keeps the ban when the NFR-09 text rule is disabled on the line", async () => {
    const code = [
      "export const A = ({ h }: { h: string }) => (",
      "  // eslint-disable-next-line balcao/no-literal-text, no-restricted-syntax",
      '  <div title="Olá" dangerouslySetInnerHTML={{ __html: h }} />',
      ");",
    ].join("\n");
    expect(await errorsCiting(code, "SR-03")).not.toEqual([]);
  });
});
