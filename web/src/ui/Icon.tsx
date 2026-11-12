import { cx } from "./cx";
import styles from "./Icon.module.css";

// The project's own marks on buttons and links, and its arrows: a 16 px grid,
// the page's 1.5 px rule, square joins (docs/prototype, the brief's §0). No
// icon library. Decorative: the word beside each mark names the control.
const PATHS = {
  back: ["M14 8H2.5M7 3.5L2.5 8 7 12.5"],
  send: ["M2 8h11.5M9 3.5L13.5 8 9 12.5"],
  out: ["M4.5 11.5l7-7M5.5 4.25h6.25v6.25"],
  envelope: ["M1.75 3.75h12.5v8.5H1.75zM2 4.25l6 4.75 6-4.75"],
  reset: ["M3.2 6.2A5.25 5.25 0 1 1 2.75 8M3 2.5v3.75h3.75"],
  bin: [
    "M2.5 4.5h11M6.25 4.25v-1.5h3.5v1.5M4 4.75l.65 8.5h6.7l.65-8.5M6.75 7.25v3.5M9.25 7.25v3.5",
  ],
  tag: ["M2.25 2.25h5.5l6 6-5.5 5.5-6-6z", "M5 5h.01"],
  // The tag's hole is a dot: a square cap on a path of no length.
  clinical: ["M6 2h4v4h4v4h-4v4H6v-4H2V6h4z"],
  speech: ["M2.25 2.75h11.5v8H7.5l-3.25 2.75v-2.75h-2z"],
} as const;

export type IconName = keyof typeof PATHS;

export function Icon({
  name,
  className,
}: {
  name: IconName;
  className?: string | undefined;
}) {
  return (
    <svg
      className={cx(styles.icon, className)}
      viewBox="0 0 16 16"
      aria-hidden="true"
      focusable="false"
    >
      {PATHS[name].map((d) => (
        <path
          key={d}
          d={d}
          strokeLinecap={d.endsWith("h.01") ? "square" : undefined}
        />
      ))}
    </svg>
  );
}

// The pharmacy's cross: the one nod, beside the name.
export function Cross({ className }: { className?: string | undefined }) {
  return (
    <svg
      className={cx(styles.cross, className)}
      viewBox="0 0 12 12"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M4 0h4v4h4v4H8v4H4V8H0V4h4z" />
    </svg>
  );
}
