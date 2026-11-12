import { afterEach, describe, expect, it } from "vitest";
import { serverClock, setServerClock } from "./api";

// A Date has whole seconds, so an answer only places the server's clock
// between its second and the next one plus the round trip (review findings
// C3 and R2 of pull request #17).
describe("FR-12 the server's clock, from the answers' Date", () => {
  const date = "Thu, 12 Nov 2026 15:05:10 GMT";
  const second = Date.parse("2026-11-12T15:05:10Z");

  afterEach(() => {
    serverClock.offset = 0;
  });

  it("leaves a clock the answer allows as it is", () => {
    setServerClock(date, second + 650, second + 700);
    expect(serverClock.offset).toBe(0);

    setServerClock(date, second + 900, second + 1_040);
    expect(serverClock.offset).toBe(0);
  });

  it("moves a clock behind or ahead to the middle of what the answer allows", () => {
    setServerClock(date, second - 120_050, second - 120_000);
    expect(serverClock.offset).toBe(120_000 + 525);

    serverClock.offset = 0;
    setServerClock(date, second + 4_950, second + 5_000);
    expect(serverClock.offset).toBe(525 - 5_000);
  });

  it("keeps the clock it has while the next answer allows it", () => {
    setServerClock(date, second - 120_050, second - 120_000);
    const offset = serverClock.offset;

    setServerClock(
      "Thu, 12 Nov 2026 15:05:12 GMT",
      second + 2_100 - offset,
      second + 2_150 - offset,
    );
    expect(serverClock.offset).toBe(offset);
  });

  it("does nothing with an answer that has no Date", () => {
    setServerClock(null, second, second + 50);
    setServerClock("yesterday", second, second + 50);
    expect(serverClock.offset).toBe(0);
  });
});
