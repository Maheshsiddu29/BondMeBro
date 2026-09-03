import type { Address } from "viem";

import type { TokenMeta } from "@/lib/format";

/**
 * Token metadata read from the chain, never from a shipped list.
 *
 * The previous frontend carried a fixed five-token registry and fell back to 18 decimals
 * for anything else, which cannot represent a 6- or 8-decimal pair correctly and made a
 * custom-decimal pool unusable. Decimals and symbol are properties of a contract on a
 * specific chain, so the cache key is chainId + address and nothing is assumed.
 */
export type MetadataReader = {
  readDecimals: (address: Address) => Promise<number>;
  readSymbol: (address: Address) => Promise<string>;
};

const cache = new Map<string, TokenMeta>();

function key(chainId: number, address: Address) {
  return `${chainId}:${address.toLowerCase()}`;
}

export function cachedTokenMeta(chainId: number, address: Address): TokenMeta | undefined {
  return cache.get(key(chainId, address));
}

export function primeTokenMeta(chainId: number, meta: TokenMeta) {
  cache.set(key(chainId, meta.address), meta);
}

export function clearTokenMetaCache() {
  cache.clear();
}

/**
 * Fetches and caches metadata for one token.
 *
 * A token whose `decimals()` cannot be read is not given a default: the caller is told the
 * metadata is unavailable and the UI fails closed rather than formatting with a guess.
 */
export async function loadTokenMeta(
  chainId: number,
  address: Address,
  reader: MetadataReader,
): Promise<TokenMeta> {
  const cached = cachedTokenMeta(chainId, address);
  if (cached) return cached;

  const [decimals, symbol] = await Promise.all([
    reader.readDecimals(address),
    reader.readSymbol(address).catch(() => ""),
  ]);

  if (!Number.isInteger(decimals) || decimals < 0 || decimals > 36) {
    throw new Error(`Token ${address} reported an unusable decimals() value.`);
  }

  const meta: TokenMeta = {
    address,
    decimals,
    // A token with no readable symbol still has a usable identity; a truncated address is
    // honest, where a hardcoded "WETH" would not be.
    symbol: symbol || `${address.slice(0, 6)}…${address.slice(-4)}`,
  };
  cache.set(key(chainId, address), meta);
  return meta;
}

/** Resolves the currency an amount is denominated in to its metadata, or undefined. */
export function metaForCurrency(
  currency: Address | undefined,
  tokens: { currency0?: TokenMeta; currency1?: TokenMeta },
): TokenMeta | undefined {
  if (!currency) return undefined;
  const normalized = currency.toLowerCase();
  if (tokens.currency0 && tokens.currency0.address.toLowerCase() === normalized) return tokens.currency0;
  if (tokens.currency1 && tokens.currency1.address.toLowerCase() === normalized) return tokens.currency1;
  return undefined;
}
