import { ESLint } from "eslint";
import { fileURLToPath } from "node:url";

const eslint = new ESLint({
  cwd: fileURLToPath(new URL("../..", import.meta.url)),
});

// Lints `code` as if it were src/App.tsx, an existing file, so the type-aware
// parser accepts it; a parse error throws instead of passing for a finding.
export async function lint(code: string): Promise<ESLint.LintResult> {
  const [result] = await eslint.lintText(code, { filePath: "src/App.tsx" });
  if (!result) throw new Error("ESLint returned no result");
  const fatal = result.messages.filter((message) => message.fatal);
  if (fatal.length > 0)
    throw new Error(fatal.map((message) => message.message).join("\n"));
  return result;
}

// The error messages that cite `requirement`.
export async function errorsCiting(
  code: string,
  requirement: string,
): Promise<string[]> {
  const result = await lint(code);
  return result.messages
    .filter(
      (message) =>
        message.severity === 2 && message.message.includes(requirement),
    )
    .map((message) => message.message);
}
