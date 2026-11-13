// The tab's icon as web/index.html declares it, under a name of the kind the
// build gives it (the hash of its content). The test setup takes it away
// after each test.
export const LIT_ICON = "/assets/icon-Lit0Hash.svg";

export function tabIcon(): HTMLLinkElement {
  const link = document.createElement("link");
  link.rel = "icon";
  link.type = "image/svg+xml";
  link.setAttribute("href", LIT_ICON);
  document.head.append(link);
  return link;
}
