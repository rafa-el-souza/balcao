// @vitest-environment node
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import { lint } from "./lint";

const packageJson = JSON.parse(
  readFileSync(new URL("../../package.json", import.meta.url), "utf8"),
) as { scripts: Record<string, string> };

// Review finding C3 on pull request #1: the hooks preset reports a missing
// effect dependency as a warning, and the lint script exited 0 on warnings.
describe(
  "NFR-08 a lint warning fails the lint step",
  { timeout: 30_000 },
  () => {
    it("fails on an effect that misses a dependency", async () => {
      const code = [
        'import { useEffect } from "react";',
        "declare function poll(cursor: string): void;",
        "export function usePoll(cursor: string) {",
        "  useEffect(() => {",
        "    const id = setInterval(() => { poll(cursor); }, 3000);",
        "    return () => { clearInterval(id); };",
        "  }, []);",
        "}",
      ].join("\n");
      const result = await lint(code);
      const maxWarnings = /--max-warnings[ =](\d+)/.exec(
        packageJson.scripts.lint ?? "",
      )?.[1];

      expect(result.warningCount).toBeGreaterThan(0);
      expect(maxWarnings).toBeDefined();
      expect(result.warningCount).toBeGreaterThan(Number(maxWarnings));
    });
  },
);
