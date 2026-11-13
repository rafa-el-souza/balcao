import { render } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { LIT_ICON, tabIcon } from "../test/tabIcon";
import { useTabLamp } from "./tabLamp";

function Page({ waiting }: { waiting: boolean }) {
  useTabLamp(waiting);
  return null;
}

// The drawing a data: address carries, whichever way it is encoded (Vite
// writes an SVG's attributes in single quotes there).
function drawing(href: string | null) {
  const [head = "", data = ""] = (href ?? "").split(",", 2);
  return head.endsWith(";base64") ? atob(data) : decodeURIComponent(data);
}

describe("Design §10 the tab's cross is a lamp", () => {
  it("dims while an answer is on its way, and lights again once it is in", () => {
    const icon = tabIcon();
    const page = render(<Page waiting={false} />);
    expect(icon.getAttribute("href")).toBe(LIT_ICON);

    page.rerender(<Page waiting />);
    const dimmed = icon.getAttribute("href");
    expect(dimmed).toMatch(/^data:image\/svg\+xml[,;]/);
    expect(drawing(dimmed)).toMatch(/opacity=["']0\.3["']/);

    page.rerender(<Page waiting={false} />);
    expect(icon.getAttribute("href")).toBe(LIT_ICON);
  });

  it("lights again when the page that dimmed it goes", () => {
    const icon = tabIcon();
    const page = render(<Page waiting />);
    expect(icon.getAttribute("href")).not.toBe(LIT_ICON);

    page.unmount();
    expect(icon.getAttribute("href")).toBe(LIT_ICON);
  });

  it("leaves a document without the icon as it is", () => {
    render(<Page waiting />);
    expect(document.head.querySelector('link[rel="icon"]')).toBeNull();
  });
});
