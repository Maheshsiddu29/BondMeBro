import { describe, expect, it } from "vitest";
import type { Address, Hex } from "viem";

import { resolveDeployment, hasRequiredHookPermissions, hookPermissionMask } from "@/lib/deployment";
import {
  assertContext,
  assertReceiptSucceeded,
  checkContext,
  ContextChangedError,
  TransactionFailedError,
  tradingReadiness,
  type IntendedContext,
} from "@/lib/guards";
import { formatAmount, parseAmount, parseUint128Amount } from "@/lib/format";

const ACCOUNT = "0x1111111111111111111111111111111111111111" as Address;
const OTHER_ACCOUNT = "0x2222222222222222222222222222222222222222" as Address;

const VALID_HOOK = "0x7b5b5759918646ce36d7f5efd1a17aa6a5e7d0c4";
const STALE_HOOK = "0xbFBa0c39308B5b189E8cd0686D3b41A64e8590cC";

const baseInput = {
  chainId: "31337",
  networkName: "Local",
  explorerUrl: "https://explorer.example",
  hook: VALID_HOOK,
  poolManager: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
  universalRouter: "0x0000000000000000000000000000000000000010",
  quoter: "0x0000000000000000000000000000000000000011",
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  currency0: "0x00000000000000000000000000000000000000a1",
  currency1: "0x00000000000000000000000000000000000000b2",
  fee: "3000",
  tickSpacing: "60",
  deploymentBlock: "1",
};

/**
 * TEST 18 — a reverted receipt is NOT success.
 * TEST 22 — an account change during approval aborts the flow.
 * TEST 23 — a chain change during approval aborts the flow.
 * TEST 24 — a wrong hook permission mask disables trading.
 */
describe("hook permission mask", () => {
  it("accepts only the 0x10C4 bit pattern", () => {
    expect(hookPermissionMask(VALID_HOOK)).toBe(0x10c4n);
    expect(hasRequiredHookPermissions(VALID_HOOK)).toBe(true);
  });

  it("rejects the previously shipped 0x10CC address", () => {
    expect(hookPermissionMask(STALE_HOOK)).toBe(0x10ccn);
    expect(hasRequiredHookPermissions(STALE_HOOK)).toBe(false);
  });

  it("disables trading when the mask is wrong", () => {
    const resolved = resolveDeployment({ ...baseInput, hook: STALE_HOOK });
    expect(resolved.status).toBe("required");
    if (resolved.status !== "required") throw new Error("unreachable");
    expect(resolved.problems.join(" ")).toMatch(/0x10C4/);

    const ready = resolveDeployment(baseInput);
    if (ready.status !== "ready") throw new Error("expected a ready deployment");
    expect(tradingReadiness(ready.deployment).canTrade).toBe(true);
    expect(tradingReadiness({ ...ready.deployment, hook: STALE_HOOK as Address }).canTrade).toBe(false);
  });
});

describe("deployment manifest", () => {
  it("fails closed for every missing value rather than defaulting", () => {
    const resolved = resolveDeployment({});
    expect(resolved.status).toBe("required");
    if (resolved.status !== "required") throw new Error("unreachable");
    expect(resolved.problems.length).toBeGreaterThan(5);
  });

  it("refuses a native-currency pool side", () => {
    const resolved = resolveDeployment({
      ...baseInput,
      currency0: "0x0000000000000000000000000000000000000000",
    });
    expect(resolved.status).toBe("required");
  });

  it("refuses unsorted currencies", () => {
    const resolved = resolveDeployment({
      ...baseInput,
      currency0: baseInput.currency1,
      currency1: baseInput.currency0,
    });
    expect(resolved.status).toBe("required");
    if (resolved.status !== "required") throw new Error("unreachable");
    expect(resolved.problems.join(" ")).toMatch(/sort below/);
  });

  it("derives the pool ID and rejects a supplied ID that disagrees", () => {
    const ready = resolveDeployment(baseInput);
    if (ready.status !== "ready") throw new Error("expected a ready deployment");
    expect(ready.deployment.poolId).toMatch(/^0x[0-9a-f]{64}$/);

    const mismatched = resolveDeployment({ ...baseInput, poolId: `0x${"00".repeat(32)}` });
    expect(mismatched.status).toBe("required");

    const matching = resolveDeployment({ ...baseInput, poolId: ready.deployment.poolId });
    expect(matching.status).toBe("ready");
  });
});

describe("chain and account binding", () => {
  const intended: IntendedContext = { address: ACCOUNT, chainId: 31_337 };

  it("aborts when the account changes mid-flow", () => {
    const check = checkContext(intended, { address: OTHER_ACCOUNT, chainId: 31_337 });
    expect(check.ok).toBe(false);
    if (check.ok) throw new Error("unreachable");
    expect(check.code).toBe("account-changed");
    expect(() => assertContext(intended, { address: OTHER_ACCOUNT, chainId: 31_337 })).toThrow(
      ContextChangedError,
    );
  });

  it("aborts when the chain changes mid-flow", () => {
    const check = checkContext(intended, { address: ACCOUNT, chainId: 1 });
    expect(check.ok).toBe(false);
    if (check.ok) throw new Error("unreachable");
    expect(check.code).toBe("chain-changed");
    expect(() => assertContext(intended, { address: ACCOUNT, chainId: 1 })).toThrow(ContextChangedError);
  });

  it("aborts when the wallet disconnects mid-flow", () => {
    const check = checkContext(intended, {});
    expect(check.ok).toBe(false);
    if (check.ok) throw new Error("unreachable");
    expect(check.code).toBe("disconnected");
  });

  it("passes only when both still match", () => {
    expect(checkContext(intended, { address: ACCOUNT, chainId: 31_337 })).toEqual({ ok: true });
    // Case differences in an address are not a context change.
    expect(checkContext(intended, { address: ACCOUNT.toUpperCase() as Address, chainId: 31_337 }).ok).toBe(true);
  });
});

describe("receipt handling", () => {
  const hash = `0x${"ab".repeat(32)}` as Hex;

  it("treats a mined reverted receipt as a failure, not a confirmation", () => {
    expect(() =>
      assertReceiptSucceeded({ status: "reverted", transactionHash: hash, blockNumber: 10n }, "swap"),
    ).toThrow(TransactionFailedError);
  });

  it("passes a successful receipt through unchanged", () => {
    const receipt = { status: "success", transactionHash: hash, blockNumber: 10n } as const;
    expect(assertReceiptSucceeded(receipt, "swap")).toBe(receipt);
  });
});

/**
 * TESTS 14-17 — mixed-decimal formatting for 18/8, 8/18, 18/6 and 6/18 pairs.
 */
describe("decimal safety", () => {
  const cases: { label: string; decimals: number; raw: bigint; formatted: string }[] = [
    { label: "18 decimals", decimals: 18, raw: 1_000_000_000_000_000_000n, formatted: "1" },
    { label: "18 decimals, dust", decimals: 18, raw: 1n, formatted: "<0.00000001" },
    { label: "8 decimals", decimals: 8, raw: 100_000_000n, formatted: "1" },
    { label: "8 decimals, fraction", decimals: 8, raw: 12_345_678n, formatted: "0.12345678" },
    { label: "6 decimals", decimals: 6, raw: 1_000_000n, formatted: "1" },
    { label: "6 decimals, fraction", decimals: 6, raw: 1n, formatted: "0.000001" },
  ];

  for (const item of cases) {
    it(`formats ${item.label} correctly`, () => {
      expect(formatAmount(item.raw, item.decimals)).toBe(item.formatted);
    });
  }

  it("18/8 pair: the same raw number means very different amounts", () => {
    const raw = 100_000_000n;
    expect(formatAmount(raw, 18)).toBe("<0.00000001");
    expect(formatAmount(raw, 8)).toBe("1");
  });

  it("8/18 pair: reversing the roles reverses the reading", () => {
    const raw = 1_000_000_000_000_000_000n;
    expect(formatAmount(raw, 8)).toBe("10000000000");
    expect(formatAmount(raw, 18)).toBe("1");
  });

  it("18/6 pair: 1 USDC is 1,000,000 raw units, not 0.000000000001", () => {
    expect(formatAmount(1_000_000n, 6)).toBe("1");
    expect(formatAmount(1_000_000n, 18)).toBe("<0.00000001");
  });

  it("6/18 pair: parsing uses each side's own decimals", () => {
    const six = parseAmount("1.5", 6);
    const eighteen = parseAmount("1.5", 18);
    expect(six.ok && six.value).toBe(1_500_000n);
    expect(eighteen.ok && eighteen.value).toBe(1_500_000_000_000_000_000n);
  });

  it("rejects excessive precision instead of silently rounding it away", () => {
    // viem's parseUnits would round 0.0000006 at six decimals to 1 raw unit.
    const rejected = parseAmount("0.0000006", 6);
    expect(rejected.ok).toBe(false);
    if (rejected.ok) throw new Error("unreachable");
    expect(rejected.reason).toMatch(/6 decimals/);

    const rounded = parseAmount("1.0000009", 6);
    expect(rounded.ok).toBe(false);
  });

  it("rejects an amount too large for the router's uint128 fields", () => {
    const tooLarge = parseUint128Amount("400000000000000000000000000000000000000000", 18);
    expect(tooLarge.ok).toBe(false);
  });

  it("rejects malformed input", () => {
    expect(parseAmount("", 18).ok).toBe(false);
    expect(parseAmount("abc", 18).ok).toBe(false);
    expect(parseAmount("-1", 18).ok).toBe(false);
    expect(parseAmount("1.2.3", 18).ok).toBe(false);
  });
});
