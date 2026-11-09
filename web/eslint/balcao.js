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

export default {
  meta: { name: "balcao" },
  rules: { "no-html-from-strings": noHtmlFromStrings },
};
