import { describe, expect, it } from "vitest";

import { BOT_URL } from "../identity";
import { BOT_QR, qrPath } from "./botQr";

// FR-19, design §6.8: the landing's QR is the bot's link. The symbol is read
// back here as a phone would read it (ISO/IEC 18004: the format bits, the
// mask, the zigzag of the codewords, Reed-Solomon over GF(256), the byte
// segment), so the committed rows and the link cannot drift apart: a new
// link is a new encoding.

const SIZE = 25;
const dark = (x: number, y: number) => BOT_QR[y]?.[x] === "#";

// Version 2's function modules: the three finders with their separators and
// the format areas beside them, the two timing lines, the one alignment
// pattern and the dark module.
function isFunction(x: number, y: number) {
  return (
    (x <= 8 && y <= 8) ||
    (x >= SIZE - 8 && y <= 8) ||
    (x <= 8 && y >= SIZE - 8) ||
    x === 6 ||
    y === 6 ||
    (x >= 16 && x <= 20 && y >= 16 && y <= 20)
  );
}

function bits(positions: [number, number][]) {
  return positions.reduce(
    (value, [x, y], index) => value | ((dark(x, y) ? 1 : 0) << index),
    0,
  );
}

const range = (from: number, to: number) =>
  Array.from({ length: to - from }, (_, index) => from + index);

const FORMAT_FIRST: [number, number][] = [
  ...range(0, 6).map((i) => [8, i] as [number, number]),
  [8, 7],
  [8, 8],
  [7, 8],
  ...range(9, 15).map((i) => [14 - i, 8] as [number, number]),
];
const FORMAT_SECOND: [number, number][] = [
  ...range(0, 8).map((i) => [SIZE - 1 - i, 8] as [number, number]),
  ...range(8, 15).map((i) => [8, SIZE - 15 + i] as [number, number]),
];

const MASKS: ((x: number, y: number) => boolean)[] = [
  (x, y) => (x + y) % 2 === 0,
  (_x, y) => y % 2 === 0,
  (x) => x % 3 === 0,
  (x, y) => (x + y) % 3 === 0,
  (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0,
  (x, y) => ((x * y) % 2) + ((x * y) % 3) === 0,
  (x, y) => (((x * y) % 2) + ((x * y) % 3)) % 2 === 0,
  (x, y) => (((x + y) % 2) + ((x * y) % 3)) % 2 === 0,
];

// The data modules in the order they are read: two columns at a time from
// the right, up and down in turn, skipping the vertical timing line.
function dataPositions() {
  const positions: [number, number][] = [];
  for (let right = SIZE - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let vertical = 0; vertical < SIZE; vertical++) {
      for (let j = 0; j < 2; j++) {
        const x = right - j;
        const upward = ((right + 1) & 2) === 0;
        const y = upward ? SIZE - 1 - vertical : vertical;
        if (!isFunction(x, y)) positions.push([x, y]);
      }
    }
  }
  return positions;
}

function gfMultiply(x: number, y: number) {
  let z = 0;
  for (let i = 7; i >= 0; i--) {
    z = (z << 1) ^ ((z >>> 7) * 0x11d);
    z ^= ((y >>> i) & 1) * x;
  }
  return z;
}

function format() {
  const raw = bits(FORMAT_FIRST) ^ 0x5412;
  let remainder = raw;
  for (let i = 14; i >= 10; i--) {
    if ((remainder >>> i) & 1) remainder ^= 0x537 << (i - 10);
  }
  return { raw, remainder, level: raw >>> 13, mask: (raw >>> 10) & 0b111 };
}

function codewords() {
  const masked = MASKS[format().mask];
  if (!masked) throw new Error("no such mask");
  const read = dataPositions().map(([x, y]) =>
    dark(x, y) !== masked(x, y) ? 1 : 0,
  );
  return range(0, 44).map((index) =>
    read
      .slice(index * 8, index * 8 + 8)
      .reduce<number>((byte, bit) => (byte << 1) | bit, 0),
  );
}

describe("FR-19 the landing's QR, the bot's link", () => {
  it("is a version 2 symbol: 25 rows of 25 modules", () => {
    expect(BOT_QR).toHaveLength(SIZE);
    for (const row of BOT_QR) expect(row).toMatch(/^[#.]{25}$/);
  });

  it("has its three finders, its timing lines, its alignment pattern and its dark module", () => {
    const finder = (left: number, top: number) =>
      range(0, 7).every((dy) =>
        range(0, 7).every((dx) => {
          const ring = Math.max(Math.abs(dx - 3), Math.abs(dy - 3));
          return dark(left + dx, top + dy) === (ring !== 2);
        }),
      );
    expect([finder(0, 0), finder(SIZE - 7, 0), finder(0, SIZE - 7)]).toEqual([
      true,
      true,
      true,
    ]);
    for (const i of range(8, SIZE - 8)) {
      expect([dark(i, 6), dark(6, i)]).toEqual([i % 2 === 0, i % 2 === 0]);
    }
    for (const dy of range(-2, 3)) {
      for (const dx of range(-2, 3)) {
        const ring = Math.max(Math.abs(dx), Math.abs(dy));
        expect(dark(18 + dx, 18 + dy)).toBe(ring !== 1);
      }
    }
    expect(dark(8, SIZE - 8)).toBe(true);
  });

  it("carries the same format bits twice, a valid code word of level M", () => {
    expect(bits(FORMAT_SECOND)).toBe(bits(FORMAT_FIRST));
    expect(format()).toMatchObject({ remainder: 0, level: 0b00 });
  });

  it("holds codewords that Reed-Solomon accepts, all sixteen syndromes zero", () => {
    const words = codewords();
    let alpha = 1;
    const syndromes = range(0, 16).map(() => {
      const value = words.reduce(
        (sum, word) => gfMultiply(sum, alpha) ^ word,
        0,
      );
      alpha = gfMultiply(alpha, 2);
      return value;
    });

    expect(syndromes.every((value) => value === 0)).toBe(true);
  });

  it("reads back as the bot's link, in one byte segment", () => {
    const stream = codewords()
      .slice(0, 28)
      .flatMap((word) => range(0, 8).map((i) => (word >>> (7 - i)) & 1));
    const take = (count: number) =>
      stream
        .splice(0, count)
        .reduce<number>((value, bit) => (value << 1) | bit, 0);

    expect(take(4)).toBe(0b0100);
    const length = take(8);
    const text = new TextDecoder().decode(
      Uint8Array.from(range(0, length).map(() => take(8))),
    );

    expect(text).toBe(BOT_URL);
  });

  it("draws one rectangle per run of dark modules, which together are the dark modules", () => {
    const drawn = new Set<string>();
    for (const [, x, y, width] of qrPath().matchAll(
      /M(\d+) (\d+)h(\d+)v1h-\3z/g,
    )) {
      for (const dx of range(0, Number(width))) {
        drawn.add(String(Number(x) + dx) + "," + String(y));
      }
    }
    const expected = new Set(
      BOT_QR.flatMap((row, y) =>
        range(0, SIZE)
          .filter((x) => row[x] === "#")
          .map((x) => String(x) + "," + String(y)),
      ),
    );

    expect(drawn).toEqual(expected);
  });
});
