import { encodePacked, isAddress, type Address, type Hex } from "viem";

/**
 * BondMeBro hookData, version 2.
 *
 * The wire format is a packed 37-byte message and nothing else:
 *
 *   byte 0      uint8   version, always 2
 *   bytes 1-20  address refundRecipient
 *   bytes 21-36 uint128 maxBondAmount, in raw units of the COLLATERAL token
 *
 * This mirrors src/libraries/HookDataCodec.sol exactly. Version 1 is rejected by the
 * contract before any field is read, and the fields are packed rather than ABI-encoded,
 * so a 96-byte padded payload fails the length check too.
 *
 * The collateral token is the OUTPUT for an exact-input swap and the INPUT for an
 * exact-output swap, so `maxBondAmount` is never denominated in the token the user typed
 * an amount into for exact input.
 */
export const HOOK_DATA_VERSION = 2;
export const HOOK_DATA_LENGTH_BYTES = 37;

export const UINT128_MAX = (1n << 128n) - 1n;

/**
 * The exact-input collateral ceiling, per INTEGRATION.md § 2 and ADR-0008 § 8.
 *
 * The collateral rate depends on where the pool price sat at the start of whichever block
 * the transaction lands in, which cannot be known when quoting. A quote-derived ceiling
 * would reject swaps whose final net output is still acceptable, so exact input hands the
 * hook an unbounded ceiling and relies on `amountOutMinimum` — checked against the net
 * receipt — for protection. The hook's own 1% rate cap still applies.
 */
export const EXACT_INPUT_MAX_BOND_AMOUNT = UINT128_MAX;

export class HookDataError extends Error {}

export type HookDataFields = {
  refundRecipient: Address;
  maxBondAmount: bigint;
};

/**
 * Encodes a version 2 payload, refusing anything the contract would refuse.
 *
 * Validating here rather than letting `encodePacked` throw keeps the failure legible and
 * keeps an invalid ceiling from reaching a wallet prompt.
 */
export function encodeHookData({ refundRecipient, maxBondAmount }: HookDataFields): Hex {
  if (!refundRecipient || !isAddress(refundRecipient)) {
    throw new HookDataError("The refund recipient must be a valid address.");
  }
  if (BigInt(refundRecipient) === 0n) {
    throw new HookDataError("The refund recipient must not be the zero address.");
  }
  if (typeof maxBondAmount !== "bigint") {
    throw new HookDataError("The collateral ceiling must be an integer amount.");
  }
  if (maxBondAmount <= 0n) {
    throw new HookDataError("The collateral ceiling must be greater than zero.");
  }
  if (maxBondAmount > UINT128_MAX) {
    throw new HookDataError("The collateral ceiling does not fit in uint128.");
  }

  return encodePacked(
    ["uint8", "address", "uint128"],
    [HOOK_DATA_VERSION, refundRecipient, maxBondAmount],
  );
}

/** Reads a payload back, used by tests and by the submitted-transaction summary. */
export function decodeHookData(data: Hex): HookDataFields {
  const body = data.startsWith("0x") ? data.slice(2) : data;
  if (body.length !== HOOK_DATA_LENGTH_BYTES * 2) {
    throw new HookDataError(
      `hookData must be ${HOOK_DATA_LENGTH_BYTES} bytes; received ${body.length / 2}.`,
    );
  }
  const version = Number.parseInt(body.slice(0, 2), 16);
  if (version !== HOOK_DATA_VERSION) {
    throw new HookDataError(`Unsupported hookData version ${version}.`);
  }
  const refundRecipient = `0x${body.slice(2, 42)}` as Address;
  const maxBondAmount = BigInt(`0x${body.slice(42, 74)}`);
  if (BigInt(refundRecipient) === 0n) throw new HookDataError("Zero refund recipient.");
  if (maxBondAmount === 0n) throw new HookDataError("Zero collateral ceiling.");
  return { refundRecipient, maxBondAmount };
}
