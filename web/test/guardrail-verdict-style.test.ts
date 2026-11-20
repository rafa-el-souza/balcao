// @vitest-environment node
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

// FR-20, FR-12: the guardrail's row that found clinical advice is a rule at
// work, drawn in the instrument's own ink as a tool's refusal is. Review
// finding V5 of pull request #54: the refused state styled only a tool's
// outcome, which the guardrail's row has none of, so its word kept the
// quieter ink of a stop reason; and in the suite a CSS module names any
// class it is asked for, so only the stylesheet itself can show the rule.
const read = (path: string) =>
  readFileSync(new URL(path, import.meta.url), "utf8");

describe("FR-20 FR-12 the guardrail's clinical verdict in the instrument's own ink", () => {
  it("styles the verdict's word in the refused state, beside a tool's outcome", () => {
    const rule =
      /\.event\[data-state="refused"\] \.outcome,\s*\.event\[data-state="refused"\] \.verdict \{[^}]*color: var\(--color-instrument-ink\);[^}]*font-weight: 700;/;

    expect(read("../src/trace/Rows.module.css")).toMatch(rule);
  });

  it("draws the verdict's word with that class", () => {
    expect(read("../src/trace/Rows.tsx")).toContain(
      "className={cx(styles.stop, styles.verdict)}",
    );
  });
});
