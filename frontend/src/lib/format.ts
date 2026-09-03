import { formatUnits, parseUnits } from "viem";

/**
 * Decimal-safe amount handling.
 *
 * Every blockchain quantity in this app is a bigint in the raw units of a specific token,
 * and every formatter takes that token's actual decimals. Nothing assumes 18, and
 * `parseEther`/`formatEther` are never used: they are 18-decimal helpers and are wrong for
 * a 6- or 8-decimal ERC20.
 */

export type TokenMeta = {
  address: `0x${string}`;
  symbol: string;
  decimals: number;
};

export class AmountError extends Error {}

export type ParsedAmount =
  | { ok: true; value: bigint }
  | { ok: false; reason: string };

/**
 * Parses a user-typed decimal string into raw units.
 *
 * Excess fractional precision is REJECTED rather than silently rounded. viem's parseUnits
 * rounds a seventh decimal place away on a 6-decimal token, which would sign a different
 * amount from the one on screen.
 */
export function parseAmount(input: string, decimals: number): ParsedAmount {
  const normalized = input.replace(/,/g, "").trim();
  if (!normalized) return { ok: false, reason: "Enter an amount." };
  if (!/^\d*(\.\d*)?$/.test(normalized)) return { ok: false, reason: "Amounts may only contain digits and one decimal point." };
  if (normalized === "." || normalized === "") return { ok: false, reason: "Enter an amount." };

  const [, fraction = ""] = normalized.split(".");
  if (fraction.length > decimals) {
    return {
      ok: false,
      reason: `This token has ${decimals} decimals; remove the extra ${fraction.length - decimals} digit${
        fraction.length - decimals === 1 ? "" : "s"
      }.`,
    };
  }

  try {
    const value = parseUnits(normalized, decimals);
    if (value < 0n) return { ok: false, reason: "Amounts cannot be negative." };
    return { ok: true, value };
  } catch {
    return { ok: false, reason: "That amount could not be read." };
  }
}

/** Parses and additionally requires the result to fit the router's uint128 fields. */
export function parseUint128Amount(input: string, decimals: number): ParsedAmount {
  const parsed = parseAmount(input, decimals);
  if (!parsed.ok) return parsed;
  if (parsed.value > (1n << 128n) - 1n) {
    return { ok: false, reason: "That amount is too large for a single swap." };
  }
  return parsed;
}

/**
 * Formats raw units for display using the token's real decimals.
 *
 * A non-zero amount that would render as all zeros at the requested precision shows a
 * "less than" marker instead, so a real 1-raw-unit balance is never displayed as 0.
 */
export function formatAmount(value: bigint | undefined, decimals: number, digits = 8): string {
  if (typeof value !== "bigint") return "—";
  const formatted = formatUnits(value, decimals);
  const [whole, fraction = ""] = formatted.split(".");
  const trimmed = fraction.slice(0, digits).replace(/0+$/, "");
  if (trimmed) return `${whole}.${trimmed}`;
  if (value > 0n && whole === "0") return `<0.${"0".repeat(Math.max(0, digits - 1))}1`;
  return whole;
}

/** Formats an amount together with its symbol. Both come from the same token record. */
export function formatToken(value: bigint | undefined, token: TokenMeta | undefined, digits = 8): string {
  if (!token) return "—";
  return `${formatAmount(value, token.decimals, digits)} ${token.symbol}`;
}

/** Raw-unit display, for thresholds whose unit is raw units rather than tokens. */
export function formatRawUnits(value: bigint | undefined): string {
  if (typeof value !== "bigint") return "—";
  return new Intl.NumberFormat("en-US").format(value);
}

export function formatCount(value: number | bigint | undefined): string {
  if (value === undefined) return "—";
  return new Intl.NumberFormat("en-US").format(Number(value));
}

export function formatBlock(value: bigint | undefined): string {
  return typeof value === "bigint" ? value.toString() : "—";
}

export function formatAddress(value?: string): string {
  if (!value) return "—";
  return `${value.slice(0, 6)}…${value.slice(-4)}`;
}

/** bps as a percentage string, e.g. 100n -> "1.00%". */
export function formatBps(value: bigint | undefined): string {
  if (typeof value !== "bigint") return "—";
  const whole = value / 100n;
  const fraction = value % 100n;
  return `${whole}.${fraction.toString().padStart(2, "0")}%`;
}
