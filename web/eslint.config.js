import js from "@eslint/js";
import { defineConfig, globalIgnores } from "eslint/config";
import prettier from "eslint-config-prettier/flat";
import jsxA11y from "eslint-plugin-jsx-a11y";
import reactHooks from "eslint-plugin-react-hooks";
import globals from "globals";
import tseslint from "typescript-eslint";

export default defineConfig([
  globalIgnores(["dist", "coverage", "playwright-report", "test-results"]),
  {
    files: ["**/*.{ts,tsx}"],
    extends: [
      js.configs.recommended,
      tseslint.configs.strictTypeChecked,
      reactHooks.configs.flat.recommended,
      jsxA11y.flatConfigs.recommended,
    ],
    languageOptions: {
      ecmaVersion: 2023,
      globals: globals.browser,
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      "no-restricted-syntax": [
        "error",
        {
          selector: "JSXAttribute[name.name='dangerouslySetInnerHTML']",
          message:
            "Threat model SR-03: render text; HTML from a string is never inserted.",
        },
        {
          selector: "JSXText[value=/\\S/]",
          message:
            "Design NFR-09: user-facing text comes from the locale files through t().",
        },
        {
          selector:
            "JSXAttribute[name.name=/^(alt|aria-label|placeholder|title)$/] > Literal",
          message:
            "Design NFR-09: user-facing text comes from the locale files through t().",
        },
      ],
    },
  },
  prettier,
]);
