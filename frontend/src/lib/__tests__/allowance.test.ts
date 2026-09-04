import { describe, expect, it } from "vitest";

import {
  allowanceStatus,
  AllowanceError,
  SESSION_DURATION_SECONDS,
  SESSION_SWAP_MULTIPLE,
  sessionAllowanceFor,
  sessionExpiry,
  UINT160_MAX,
} from "@/lib/allowance";

/** The demo's exact-input trade: 10,000 bUSDC at six decimals. */
const USDC_SWAP = 10_000n * 10n ** 6n;
/** The demo's exact-output trade: roughly 4.11 bWETH of authorised input, at eighteen. */
const WETH_SWAP = 4_113_962_088_285_057_194n;

const NOW = 1_788_000_000;

describe("session allowance is bounded", () => {
  it("covers ten demo swaps and no more", () => {
    expect(SESSION_SWAP_MULTIPLE).toBe(10n);
    expect(sessionAllowanceFor(USDC_SWAP)).toBe(100_000n * 10n ** 6n);
    expect(sessionAllowanceFor(WETH_SWAP)).toBe(WETH_SWAP * 10n);
  });

  it("is nowhere near an unlimited approval", () => {
    const usdcSession = sessionAllowanceFor(USDC_SWAP);
    const wethSession = sessionAllowanceFor(WETH_SWAP);

    expect(usdcSession).not.toBe(UINT160_MAX);
    expect(usdcSession).not.toBe((1n << 256n) - 1n);
    expect(usdcSession).toBeLessThan(UINT160_MAX);
    expect(wethSession).toBeLessThan(UINT160_MAX);

    // And it is a small fraction of the demo wallet, not the whole balance.
    const usdcBalance = 9_000_000n * 10n ** 6n;
    const wethBalance = 3_600n * 10n ** 18n;
    expect(usdcSession * 50n).toBeLessThan(usdcBalance);
    expect(wethSession * 50n).toBeLessThan(wethBalance);
  });

  it("scales with the token's own decimals", () => {
    // Six-decimal and eighteen-decimal sessions are computed the same way, in raw units.
    expect(sessionAllowanceFor(1n * 10n ** 6n)).toBe(10n * 10n ** 6n);
    expect(sessionAllowanceFor(1n * 10n ** 18n)).toBe(10n * 10n ** 18n);
  });

  it("refuses a non-positive requirement", () => {
    expect(() => sessionAllowanceFor(0n)).toThrow(AllowanceError);
    expect(() => sessionAllowanceFor(-1n)).toThrow(AllowanceError);
  });

  it("refuses a trade too large to bound", () => {
    expect(() => sessionAllowanceFor(UINT160_MAX)).toThrow(AllowanceError);
  });

  it("expires in one hour at the Permit2 layer", () => {
    expect(SESSION_DURATION_SECONDS).toBe(3_600);
    expect(sessionExpiry(NOW)).toBe(NOW + 3_600);
  });
});

describe("approval is asked for once, then skipped", () => {
  const session = sessionAllowanceFor(USDC_SWAP);
  const liveExpiry = BigInt(NOW + 3_000);

  it("asks on the first swap of a session", () => {
    const status = allowanceStatus({
      swapRequirement: USDC_SWAP,
      tokenAllowance: 0n,
      permit2Amount: 0n,
      permit2Expiration: 0n,
      nowSeconds: NOW,
    });
    expect(status.ready).toBe(false);
    expect(status.needsFirstTimeApproval).toBe(true);
  });

  it("skips entirely once a session grant is in place", () => {
    const status = allowanceStatus({
      swapRequirement: USDC_SWAP,
      tokenAllowance: session,
      permit2Amount: session,
      permit2Expiration: liveExpiry,
      nowSeconds: NOW,
    });
    expect(status.ready).toBe(true);
    expect(status.needsFirstTimeApproval).toBe(false);
  });

  it("keeps skipping across several swaps until the session is spent", () => {
    // Ten swaps drain the session; each intermediate swap needs no approval.
    let remaining = session;
    let approvals = 0;

    for (let i = 0; i < 10; i += 1) {
      const status = allowanceStatus({
        swapRequirement: USDC_SWAP,
        tokenAllowance: remaining,
        permit2Amount: remaining,
        permit2Expiration: liveExpiry,
        nowSeconds: NOW,
      });
      if (!status.ready) approvals += 1;
      remaining -= USDC_SWAP;
    }

    expect(approvals).toBe(0);

    // The eleventh finds the session exhausted and asks again.
    const exhausted = allowanceStatus({
      swapRequirement: USDC_SWAP,
      tokenAllowance: remaining,
      permit2Amount: remaining,
      permit2Expiration: liveExpiry,
      nowSeconds: NOW,
    });
    expect(exhausted.ready).toBe(false);
  });

  it("asks again once the Permit2 grant has expired", () => {
    const status = allowanceStatus({
      swapRequirement: USDC_SWAP,
      tokenAllowance: session,
      permit2Amount: session,
      permit2Expiration: BigInt(NOW - 1),
      nowSeconds: NOW,
    });
    expect(status.permit2Ready).toBe(false);
    // The ERC20 leg is still good, so this is a renewal rather than a first-time approval.
    expect(status.tokenReady).toBe(true);
    expect(status.needsFirstTimeApproval).toBe(false);
  });

  it("treats a grant expiring within the minute as spent", () => {
    // Signing against it would race the clock between the prompt and inclusion.
    const status = allowanceStatus({
      swapRequirement: USDC_SWAP,
      tokenAllowance: session,
      permit2Amount: session,
      permit2Expiration: BigInt(NOW + 30),
      nowSeconds: NOW,
    });
    expect(status.permit2Ready).toBe(false);
  });

  it("asks when only one of the two legs is sufficient", () => {
    expect(
      allowanceStatus({
        swapRequirement: USDC_SWAP,
        tokenAllowance: session,
        permit2Amount: 0n,
        permit2Expiration: liveExpiry,
        nowSeconds: NOW,
      }).ready,
    ).toBe(false);

    expect(
      allowanceStatus({
        swapRequirement: USDC_SWAP,
        tokenAllowance: 0n,
        permit2Amount: session,
        permit2Expiration: liveExpiry,
        nowSeconds: NOW,
      }).ready,
    ).toBe(false);
  });

  it("judges sufficiency against THIS swap, not the session size", () => {
    // Exactly enough for the trade in hand is enough; no approval is forced.
    const status = allowanceStatus({
      swapRequirement: USDC_SWAP,
      tokenAllowance: USDC_SWAP,
      permit2Amount: USDC_SWAP,
      permit2Expiration: liveExpiry,
      nowSeconds: NOW,
    });
    expect(status.ready).toBe(true);
  });
});
