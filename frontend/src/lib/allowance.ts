/**
 * Demo-session allowances.
 *
 * Approving exactly one swap's requirement is the tightest possible grant, and it made the
 * demo unusable: every single swap re-ran both approvals, so a three-transaction dance stood
 * between the presenter and every trade.
 *
 * The answer is not an unlimited approval. It is a BOUNDED SESSION allowance: a small,
 * explicit multiple of the trade being made, expiring at the Permit2 layer within the hour.
 * Nothing here may use `type(uint256).max` or `type(uint160).max`.
 */

/**
 * How many demo swaps one approval should cover.
 *
 * Ten is chosen against the actual demo sizes: the exact-input rehearsal trades 10,000 bUSDC
 * and the exact-output one costs roughly 4 bWETH, so a session covers about 100,000 bUSDC or
 * 40 bWETH. Against the demo wallet's post-liquidity holdings — 9,000,000 bUSDC and 3,600
 * bWETH — that is a little over one percent of the balance, which is the point: it is sized
 * from the TRADE, not from what the wallet happens to hold.
 */
export const SESSION_SWAP_MULTIPLE = 10n;

/** Permit2 allowances are uint160. A session amount must fit, with room to spare. */
export const UINT160_MAX = (1n << 160n) - 1n;

/** Permit2 session expiry: one hour. Short enough that a stale grant lapses on its own. */
export const SESSION_DURATION_SECONDS = 3_600;

export class AllowanceError extends Error {}

/**
 * The bounded amount to grant when an approval is needed.
 *
 * @param swapRequirement What THIS swap needs: `amountIn` for exact input, `amountInMaximum`
 * for exact output.
 * @returns A bounded multiple of that requirement.
 */
export function sessionAllowanceFor(swapRequirement: bigint): bigint {
  if (typeof swapRequirement !== "bigint" || swapRequirement <= 0n) {
    throw new AllowanceError("A session allowance needs a positive swap requirement.");
  }

  const session = swapRequirement * SESSION_SWAP_MULTIPLE;

  if (session >= UINT160_MAX) {
    throw new AllowanceError("This trade is too large to cover with a bounded session allowance.");
  }

  return session;
}

/** Permit2 expiry timestamp for a session granted now. */
export function sessionExpiry(nowSeconds: number): number {
  return nowSeconds + SESSION_DURATION_SECONDS;
}

export type AllowanceStatus = {
  /** Whether the ERC20 -> Permit2 grant covers this swap. */
  tokenReady: boolean;
  /** Whether the Permit2 -> router grant covers this swap AND has not expired. */
  permit2Ready: boolean;
  /** Whether the swap can proceed without any approval transaction. */
  ready: boolean;
  /** True when this is the first approval of the session for this token. */
  needsFirstTimeApproval: boolean;
};

/**
 * Decides what, if anything, must be approved before this swap.
 *
 * The SUFFICIENCY test uses this swap's requirement — you only ever need enough for the trade
 * in front of you. The GRANT, when one is needed, is the session amount. That asymmetry is
 * what makes the second and subsequent demo swaps skip approval entirely.
 */
export function allowanceStatus({
  swapRequirement,
  tokenAllowance,
  permit2Amount,
  permit2Expiration,
  nowSeconds,
}: {
  swapRequirement: bigint;
  /** Current ERC20 allowance granted to Permit2. */
  tokenAllowance: bigint;
  /** Current Permit2 allowance granted to the router. */
  permit2Amount: bigint;
  /** Permit2 expiry timestamp, in seconds. */
  permit2Expiration: bigint;
  nowSeconds: number;
}): AllowanceStatus {
  // A grant expiring in the next minute is treated as spent: signing against it would race
  // the clock between the wallet prompt and inclusion.
  const permit2Live = permit2Expiration > BigInt(nowSeconds + 60);

  const tokenReady = tokenAllowance >= swapRequirement;
  const permit2Ready = permit2Amount >= swapRequirement && permit2Live;

  return {
    tokenReady,
    permit2Ready,
    ready: tokenReady && permit2Ready,
    needsFirstTimeApproval: !tokenReady,
  };
}
