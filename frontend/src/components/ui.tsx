"use client";

/**
 * Presentational primitives shared by the screens.
 *
 * These carry the same class names as the original design system in app/globals.css, so
 * the visual language is unchanged; only the data behind them was rebuilt.
 */
export function StatusDot({ live = false }: { live?: boolean }) {
  return <span className={`status-dot${live ? " status-dot-live" : ""}`} aria-hidden="true" />;
}

export function Badge({
  children,
  tone = "neutral",
}: {
  children: React.ReactNode;
  tone?: "neutral" | "pink" | "green" | "muted";
}) {
  return <span className={`badge badge-${tone === "pink" ? "ready" : tone === "green" ? "settled" : "muted"}`}>{children}</span>;
}

export function SectionHeading({ eyebrow, title, copy }: { eyebrow: string; title: string; copy?: string }) {
  return (
    <div className="section-heading">
      <span className="eyebrow">{eyebrow}</span>
      <h2>{title}</h2>
      {copy && <p>{copy}</p>}
    </div>
  );
}
