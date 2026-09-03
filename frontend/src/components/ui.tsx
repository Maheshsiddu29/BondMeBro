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
  tone?: "neutral" | "orange" | "green" | "muted";
}) {
  return <span className={`badge badge-${tone}`}>{children}</span>;
}

export function MetricCard({
  label,
  value,
  detail,
  icon,
  accent = false,
}: {
  label: string;
  value: string;
  detail: string;
  icon?: string;
  accent?: boolean;
}) {
  return (
    <article className={`metric-card ${accent ? "metric-card-accent" : ""}`}>
      <div className="metric-card-top">
        <span>{label}</span>
        {icon && <span className="metric-icon">{icon}</span>}
      </div>
      <strong>{value}</strong>
      <span className="metric-detail">{detail}</span>
    </article>
  );
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

export type PickerToken = { symbol: string; icon: string };

export function TokenPicker({
  label,
  token,
  options,
  onChange,
}: {
  label: string;
  token: PickerToken;
  options: PickerToken[];
  onChange: (symbol: string) => void;
}) {
  return (
    <label className="uniswap-token-picker" aria-label={label}>
      <span className="token-bubble token-purple">{token.icon}</span>
      <strong>{token.symbol}</strong>
      <span className="token-picker-chevron">⌄</span>
      <select value={token.symbol} onChange={(event) => onChange(event.target.value)}>
        {options.map((option) => (
          <option value={option.symbol} key={option.symbol}>
            {option.symbol}
          </option>
        ))}
      </select>
    </label>
  );
}
