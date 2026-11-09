// The project's own lint rules, one rule per requirement, so silencing one
// never silences another (review finding C5, pull request #1).

const SR03 =
  "Threat model SR-03: text is rendered as text; HTML from a string never reaches the DOM.";

const noHtmlFromStrings = {
  meta: {
    type: "problem",
    docs: {
      description: "SR-03: no HTML from strings, in JSX or through the DOM",
    },
    schema: [],
  },
  create(context) {
    const report = (node) => context.report({ node, message: SR03 });
    return {
      "JSXAttribute[name.name='dangerouslySetInnerHTML']": report,
      "JSXAttribute[name.name=/^srcdoc$/i]": report,
      "Property[key.name=/^(dangerouslySetInnerHTML|innerHTML|outerHTML|srcdoc)$/]":
        report,
      "Property[key.value=/^(dangerouslySetInnerHTML|innerHTML|outerHTML|srcdoc)$/]":
        report,
      "AssignmentExpression > MemberExpression.left[property.name=/^(innerHTML|outerHTML|srcdoc)$/]":
        report,
      "AssignmentExpression > MemberExpression.left[property.value=/^(innerHTML|outerHTML|srcdoc)$/]":
        report,
      "CallExpression > MemberExpression.callee[property.name=/^(insertAdjacentHTML|setHTMLUnsafe|createContextualFragment)$/]":
        report,
    };
  },
};

const NFR09 =
  "Design NFR-09: user-facing text comes from the three locale files through t(), never from code.";

// Text has at least one letter; a glyph such as × or ·, a digit or an empty
// alt="" (a decorative image) is not text.
const LETTER = "/[A-Za-zÀ-ÖØ-öø-ÿ]/";
const TEXT_ATTRIBUTE =
  "JSXAttribute[name.name=/^(alt|aria-label|aria-description|aria-roledescription|aria-valuetext|aria-placeholder|placeholder|title|label|value|caption|heading|text|description|hint|message)$/]";

// Where literal text can sit: an element's child in braces, or a text
// attribute's value, bare or in braces; directly or as a branch of ?: or &&.
const HOLDERS = [
  ":matches(JSXElement, JSXFragment) > JSXExpressionContainer",
  TEXT_ATTRIBUTE,
  `${TEXT_ATTRIBUTE} > JSXExpressionContainer`,
];
const BRANCHES = ["", " > ConditionalExpression", " > LogicalExpression"];

const LITERAL_TEXT = [
  `JSXText[value=${LETTER}]`,
  ...HOLDERS.flatMap((holder) =>
    BRANCHES.flatMap((branch) => [
      `${holder}${branch} > Literal[value=${LETTER}]`,
      `${holder}${branch} > TemplateLiteral > TemplateElement[value.raw=${LETTER}]`,
    ]),
  ),
];

const noLiteralText = {
  meta: {
    type: "problem",
    docs: { description: "NFR-09: no literal user-facing text in JSX" },
    schema: [],
  },
  create(context) {
    const report = (node) => context.report({ node, message: NFR09 });
    return Object.fromEntries(
      LITERAL_TEXT.map((selector) => [selector, report]),
    );
  },
};

export default {
  meta: { name: "balcao" },
  rules: {
    "no-html-from-strings": noHtmlFromStrings,
    "no-literal-text": noLiteralText,
  },
};
