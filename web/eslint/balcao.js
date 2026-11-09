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
const LETTER = /[A-Za-zÀ-ÖØ-öø-ÿ]/;

// Attributes and props whose value is shown or read to the visitor, compared
// without hyphens or case (aria-label and ariaLabel alike).
const TEXT_ATTRIBUTES = new Set([
  "alt",
  "arialabel",
  "ariadescription",
  "ariaroledescription",
  "ariavaluetext",
  "ariaplaceholder",
  "placeholder",
  "title",
  "label",
  "caption",
  "heading",
  "text",
  "description",
  "hint",
  "message",
  "content",
  "tooltip",
]);

// `value` is text only on the buttons an <input> draws; elsewhere (hidden
// inputs, options, submit buttons' values) it is data.
const INPUT_BUTTON_TYPES = new Set(["submit", "button", "reset"]);

function isTextAttribute(attribute) {
  if (attribute.name.type !== "JSXIdentifier") return false;
  const name = attribute.name.name;
  if (TEXT_ATTRIBUTES.has(name.replaceAll("-", "").toLowerCase())) return true;
  if (name !== "value") return false;
  const element = attribute.parent;
  if (element.name.type !== "JSXIdentifier" || element.name.name !== "input")
    return false;
  const type = element.attributes.find(
    (other) => other.type === "JSXAttribute" && other.name.name === "type",
  );
  return (
    type?.value?.type === "Literal" && INPUT_BUTTON_TYPES.has(type.value.value)
  );
}

// The literals whose value becomes rendered text: the expression itself, the
// branches of ?:, && and ??, both sides of a string +, the parts of a
// template, the elements of an array, and the object of a method call on one
// (["a", "b"].map(...)). A call's arguments are never text: t("key") is not.
function textLiterals(node, found = []) {
  if (!node) return found;
  switch (node.type) {
    case "Literal":
      if (typeof node.value === "string" && LETTER.test(node.value))
        found.push(node);
      break;
    case "TemplateLiteral":
      for (const quasi of node.quasis)
        if (LETTER.test(quasi.value.raw)) found.push(quasi);
      for (const expression of node.expressions)
        textLiterals(expression, found);
      break;
    case "ConditionalExpression":
      textLiterals(node.consequent, found);
      textLiterals(node.alternate, found);
      break;
    case "LogicalExpression":
      textLiterals(node.left, found);
      textLiterals(node.right, found);
      break;
    case "BinaryExpression":
      if (node.operator === "+") {
        textLiterals(node.left, found);
        textLiterals(node.right, found);
      }
      break;
    case "ArrayExpression":
      for (const element of node.elements) textLiterals(element, found);
      break;
    case "CallExpression":
      if (node.callee.type === "MemberExpression")
        textLiterals(node.callee.object, found);
      break;
    case "SequenceExpression":
      textLiterals(node.expressions.at(-1), found);
      break;
    case "TSAsExpression":
    case "TSSatisfiesExpression":
    case "TSNonNullExpression":
      textLiterals(node.expression, found);
      break;
  }
  return found;
}

const noLiteralText = {
  meta: {
    type: "problem",
    docs: { description: "NFR-09: no literal user-facing text in JSX" },
    schema: [],
  },
  create(context) {
    const report = (node) => context.report({ node, message: NFR09 });
    return {
      JSXText(node) {
        if (LETTER.test(node.value)) report(node);
      },
      JSXExpressionContainer(node) {
        const parent = node.parent;
        const isChild =
          parent.type === "JSXElement" || parent.type === "JSXFragment";
        const isText =
          parent.type === "JSXAttribute" && isTextAttribute(parent);
        if (isChild || isText) textLiterals(node.expression).forEach(report);
      },
      JSXAttribute(node) {
        if (node.value?.type === "Literal" && isTextAttribute(node)) {
          textLiterals(node.value).forEach(report);
        }
      },
    };
  },
};

export default {
  meta: { name: "balcao" },
  rules: {
    "no-html-from-strings": noHtmlFromStrings,
    "no-literal-text": noLiteralText,
  },
};
