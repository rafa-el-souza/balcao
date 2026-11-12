// Joins the class names that apply; a CSS Module's name may be undefined to
// the type checker, and a condition may be false.
export function cx(...names: (string | undefined | false | null)[]): string {
  return names.filter(Boolean).join(" ");
}
