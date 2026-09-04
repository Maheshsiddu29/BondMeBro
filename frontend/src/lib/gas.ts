import type { Address, Hex } from "viem";

/**
 * The single write pipeline: estimate the exact call, bound the gas, then sign it.
 *
 * A wallet left to pick its own gas limit can build a transaction the node refuses. On
 * Unichain Sepolia an unspecified limit produced a signed transaction that
 * `eth_sendRawTransaction` rejected with "gas limit too high" — after the user had already
 * approved it, which is the worst possible moment to find out. The same class of failure
 * surfaced on `settleBond` as an empty "reverted with the following reason:".
 *
 * Every write in this app therefore goes through `submitWithBoundedGas`, so there is exactly
 * one place where an estimate becomes a gas limit and exactly one margin.
 */

/**
 * The largest gas limit a single transaction may declare on this network: 2^24.
 *
 * This is NOT the block gas limit, which is 60,000,000 on Unichain Sepolia. A wallet that
 * falls back to the block limit — or to any other round number above this ceiling — builds a
 * transaction that is rejected at submission. Nothing here may use 30,000,000, 60,000,000 or
 * a block gas limit as a transaction gas limit.
 */
export const MAX_TRANSACTION_GAS = 16_777_216n;

/**
 * Safety margin over the estimate, as a divisor: a fifth is 20%.
 *
 * The estimate is taken against current state, but the transaction executes against the
 * state of whichever block includes it. For a BondMeBro swap the collateral path itself can
 * differ — a trade landing behind a large same-block swap does more work in `afterSwap` — so
 * a bare estimate is genuinely too tight.
 */
export const GAS_MARGIN_DIVISOR = 5n;

/** Raised when an estimate cannot be turned into a usable transaction gas limit. */
export class GasEstimateError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "GasEstimateError";
  }
}

/**
 * Turns a raw gas estimate into the limit to sign with, or refuses.
 *
 * Refusing matters as much as the margin does. An absurd estimate usually means the
 * simulation did not really succeed, and clamping it to the ceiling would send a transaction
 * that is expected to fail. Failing here keeps the wallet prompt from opening at all.
 *
 * @param estimatedGas Result of estimating the exact transaction about to be sent.
 * @returns The estimate plus a 20% margin.
 */
export function withGasMargin(estimatedGas: bigint): bigint {
  if (typeof estimatedGas !== "bigint") {
    throw new GasEstimateError("The gas estimate was not an integer amount.");
  }
  if (estimatedGas <= 0n) {
    // A zero estimate means the node did not actually simulate this transaction.
    throw new GasEstimateError("The gas estimate came back as zero, so nothing was submitted.");
  }

  const gasWithMargin = estimatedGas + estimatedGas / GAS_MARGIN_DIVISOR;

  if (gasWithMargin >= MAX_TRANSACTION_GAS) {
    throw new GasEstimateError(
      "The gas estimate is outside the supported transaction limit. Nothing was submitted; try a smaller amount.",
    );
  }

  return gasWithMargin;
}

/**
 * Estimates one call and signs THAT SAME call.
 *
 * The call object is passed through untouched to both the estimator and the writer, so it is
 * structurally impossible to estimate one set of arguments and sign another. Callers supply
 * thin lambdas rather than a client, which keeps viem's inference intact at the call site and
 * keeps this function trivially testable.
 *
 * @returns The submitted transaction hash and the gas limit that was signed.
 */
export async function submitWithBoundedGas<TCall>({
  call,
  chainId,
  estimateGas,
  write,
  label,
}: {
  call: TCall;
  chainId: number;
  estimateGas: (call: TCall) => Promise<bigint>;
  write: (call: TCall & { chainId: number; gas: bigint }) => Promise<Hex>;
  /** Used only for the development-mode diagnostic line. */
  label?: string;
}): Promise<{ hash: Hex; gas: bigint }> {
  const estimatedGas = await estimateGas(call);
  const gas = withGasMargin(estimatedGas);

  if (process.env.NODE_ENV !== "production") {
    // Enough to confirm the limit that was signed, and nothing about the user.
    console.info(
      `[bondmebro] ${label ?? "write"} gas ${estimatedGas} -> ${gas} with margin (ceiling ${MAX_TRANSACTION_GAS})`,
    );
  }

  const hash = await write({ ...call, chainId, gas });
  return { hash, gas };
}

/** Shape shared by every write this app makes. */
export type BoundedGasCall = {
  address: Address;
  account: Address;
};
