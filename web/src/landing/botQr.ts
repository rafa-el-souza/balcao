// The landing's QR (design §6.8, FR-19): the bot's link, BOT_URL, encoded
// once in byte mode, version 2 (25 by 25 modules), error correction level M,
// mask 1, and scanned on a phone before it was committed (PR-19). Its rows,
// "#" dark and "." light, top to bottom; botQr.test.ts reads the symbol back
// to the link, so the two cannot drift apart: a new link is a new encoding.
export const BOT_QR = [
  "#######.#.#..##...#######",
  "#.....#....##...#.#.....#",
  "#.###.#.##.#.#..#.#.###.#",
  "#.###.#..##.###...#.###.#",
  "#.###.#.......#...#.###.#",
  "#.....#.##.#.##...#.....#",
  "#######.#.#.#.#.#.#######",
  "...........#..#.#........",
  "#.#...##..####..#..#..#.#",
  ".#.#.#.####....##.#..#.##",
  ".#..######...#.#...####.#",
  ".###....#.##......##.#...",
  ".....##..#..#..##.#.....#",
  ".#...#.####....##.##...##",
  "###.#.###..###.##....##.#",
  "...#....#.#.#.##.#.###...",
  "##.#.##.#.##...######..#.",
  "........######..#...#...#",
  "#######.#.##.#.##.#.#...#",
  "#.....#..#.##.###...#...#",
  "#.###.#..##.#..######..#.",
  "#.###.#..#####.###..#.##.",
  "#.###.#.#####....#.###.##",
  "#.....#..#.#..#.##.##....",
  "#######.#..###.##.#..#..#",
] as const;

// The dark modules as one SVG path, a rectangle per run of a row, on a grid
// of one unit a module.
export function qrPath(rows: readonly string[] = BOT_QR) {
  return rows
    .flatMap((row, y) =>
      Array.from(row.matchAll(/#+/g), (run) => {
        const width = String(run[0].length);
        return `M${String(run.index)} ${String(y)}h${width}v1h-${width}z`;
      }),
    )
    .join("");
}
