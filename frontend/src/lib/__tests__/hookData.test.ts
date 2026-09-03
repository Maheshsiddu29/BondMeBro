import { describe, expect, it } from "vitest";

import {
  decodeHookData,
  encodeHookData,
  EXACT_INPUT_MAX_BOND_AMOUNT,
  HOOK_DATA_LENGTH_BYTES,
  HookDataError,
  UINT128_MAX,
} from "@/lib/hookData";

/**
 * TEST 4 — HookData v2 exact 37-byte encoding.
 * TEST 9 — exact-input maxBondAmount is the uint128 maximum.
 */
describe("hookData v2", () => {
  const recipient = "0x1111111111111111111111111111111111111111" as const;

  it("produces exactly 37 packed bytes starting with version 2", () => {
    const encoded = encodeHookData({ refundRecipient: recipient, maxBondAmount: 10_000n });
    expect(encoded).toBe(
      "0x02" + "1111111111111111111111111111111111111111" + "00000000000000000000000000002710",
    );
    expect((encoded.length - 2) / 2).toBe(HOOK_DATA_LENGTH_BYTES);
    expect(encoded.slice(0, 4)).toBe("0x02");
  });

  it("is not the ABI-padded 96-byte form", () => {
    const encoded = encodeHookData({ refundRecipient: recipient, maxBondAmount: 1n });
    expect((encoded.length - 2) / 2).not.toBe(96);
  });

  it("pins the uint128 maximum ceiling", () => {
    const encoded = encodeHookData({
      refundRecipient: recipient,
      maxBondAmount: EXACT_INPUT_MAX_BOND_AMOUNT,
    });
    expect(EXACT_INPUT_MAX_BOND_AMOUNT).toBe(340282366920938463463374607431768211455n);
    expect(EXACT_INPUT_MAX_BOND_AMOUNT).toBe(UINT128_MAX);
    expect(encoded.endsWith("f".repeat(32))).toBe(true);
  });

  it("round-trips", () => {
    const encoded = encodeHookData({ refundRecipient: recipient, maxBondAmount: 123_456_789n });
    expect(decodeHookData(encoded)).toEqual({ refundRecipient: recipient, maxBondAmount: 123_456_789n });
  });

  it("refuses what the contract refuses", () => {
    expect(() =>
      encodeHookData({
        refundRecipient: "0x0000000000000000000000000000000000000000",
        maxBondAmount: 1n,
      }),
    ).toThrow(HookDataError);
    expect(() => encodeHookData({ refundRecipient: recipient, maxBondAmount: 0n })).toThrow(HookDataError);
    expect(() => encodeHookData({ refundRecipient: recipient, maxBondAmount: UINT128_MAX + 1n })).toThrow(
      HookDataError,
    );
  });

  it("rejects a version 1 payload on decode", () => {
    const v1 = ("0x01" + "1111111111111111111111111111111111111111" + "0".repeat(32)) as `0x${string}`;
    expect(() => decodeHookData(v1)).toThrow(/version 1/i);
  });
});
