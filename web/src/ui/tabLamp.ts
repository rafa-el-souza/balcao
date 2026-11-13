import { useEffect } from "react";

import dimmed from "../favicon/icon-dim.svg?inline";

// The tab's icon (web/index.html) is the pharmacy's cross on its paper. While
// an answer is on its way the cross dims, as the one beside "pensando…" does,
// and lights again once the answer is in (design §10, note of 2026-11-13): two
// still pictures and never a motion, so reduced motion has nothing to stop.
// The dim one travels inside the bundle, so dimming asks the server for
// nothing. A browser that shows the .ico instead (Safari before 26) keeps the
// lit cross.
const TAB_ICON = 'link[rel="icon"][type="image/svg+xml"]';

export function useTabLamp(waiting: boolean) {
  useEffect(() => {
    if (!waiting) return;
    const icon = document.head.querySelector<HTMLLinkElement>(TAB_ICON);
    const lit = icon?.getAttribute("href") ?? null;
    if (!icon || lit === null) return;
    icon.setAttribute("href", dimmed);
    return () => {
      icon.setAttribute("href", lit);
    };
  }, [waiting]);
}
