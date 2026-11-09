// @vitest-environment node
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

// Review finding C4 on pull request #1: `npm audit --omit=dev` still audited
// toolchain packages that runtime packages list as optional peers (npm flags
// them devOptional and omits them only when optional is omitted too), so a
// toolchain advisory would block every pull request, against SR-27.
type LockedPackage = {
  dev?: boolean;
  optional?: boolean;
  devOptional?: boolean;
  devDependencies?: Record<string, string>;
};
const lock = JSON.parse(
  readFileSync(new URL("../package-lock.json", import.meta.url), "utf8"),
) as { packages: Record<string, LockedPackage> };
const workflow = readFileSync(
  new URL("../../.github/workflows/ci.yml", import.meta.url),
  "utf8",
);

const nameOf = (path: string) => path.replace(/^.*node_modules\//, "");
const packages = Object.entries(lock.packages).filter(([path]) => path !== "");

describe("SR-27 the npm audit gates the runtime tree only", () => {
  const command = /npm audit [^\n]*/.exec(workflow)?.[0] ?? "";
  const omitted = new Set(
    [...command.matchAll(/--omit[ =](\w+)/g)].map((match) => match[1]),
  );

  it("fails CI at high and above", () => {
    expect(command).toContain("--audit-level=high");
  });

  it("leaves every root devDependency out of the audited set", () => {
    // npm's rule (arborist Node#shouldOmit): dev when dev is omitted,
    // optional when optional is omitted, devOptional only when both are.
    const audited = packages
      .filter(([, pkg]) => {
        if (pkg.dev && omitted.has("dev")) return false;
        if (pkg.optional && omitted.has("optional")) return false;
        if (pkg.devOptional && omitted.has("dev") && omitted.has("optional"))
          return false;
        return true;
      })
      .map(([path]) => nameOf(path));
    const toolchain = Object.keys(lock.packages[""]?.devDependencies ?? {});

    expect(audited.filter((name) => toolchain.includes(name))).toEqual([]);
  });

  it("omits no package that only runtime code needs", () => {
    const runtimeOptional = packages
      .filter(([, pkg]) => pkg.optional && !pkg.dev && !pkg.devOptional)
      .map(([path]) => nameOf(path));

    expect(runtimeOptional).toEqual([]);
  });
});
