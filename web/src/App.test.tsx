import { act, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";

import { App } from "./App";
import i18n, { DEFAULT_LOCALE } from "./i18n";

describe("NFR-09 app shell", () => {
  afterEach(async () => {
    await act(() => i18n.changeLanguage(DEFAULT_LOCALE));
  });

  it("renders in pt-BR by default, from the locale file", () => {
    render(<App />);

    expect(
      screen.getByRole("heading", { level: 1, name: "Balcão" }),
    ).toBeInTheDocument();
    expect(screen.getByText("Em construção.")).toBeInTheDocument();
  });

  it("follows a language change to English and Spanish", async () => {
    render(<App />);

    await act(() => i18n.changeLanguage("en"));
    expect(screen.getByText("Under construction.")).toBeInTheDocument();

    await act(() => i18n.changeLanguage("es"));
    expect(screen.getByText("En construcción.")).toBeInTheDocument();
  });
});
