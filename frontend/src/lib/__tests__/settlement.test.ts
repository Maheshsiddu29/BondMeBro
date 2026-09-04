import { describe, expect, it } from "vitest";
import { BaseError, ContractFunctionRevertedError } from "viem";

import { BondState, type Bond } from "@/lib/bond";
import { describePreflightError } from "@/lib/errors";
import {
  isSettledByStorage,
  resolveSettlementOutcome,
  settlementPreflight,
} from "@/lib/settlement";

function bond(overrides: Partial<Bond> = {}): Bond {
  return {
    refundRecipient: "0xA5B709025224bA08B8eFfF1b0D1d28E970A34Cf3",
    openBlock: 61_621_708n,
    maturityBlock: 61_621_718n,
    poolIndex: 1n,
    variableLegAmount: 3_948_632_137_588_245_195n,
    tickBefore: -198_080n,
    tickAfter: -197_882n,
    collateralBps: 50n,
    collateralIsCurrency0: true,
    state: BondState.Finalized,
    ...overrides,
  };
}

/** The live bond used for the demo, at a block well past its maturity. */
const LIVE_CURRENT_BLOCK = 61_624_750n;

describe("settlement preflight", () => {
  it("admits a finalized, matured bond", () => {
    const result = settlementPreflight(bond(), LIVE_CURRENT_BLOCK);
    expect(result.ok).toBe(true);
  });

  it("admits a bond exactly at maturity", () => {
    expect(settlementPreflight(bond(), 61_621_718n).ok).toBe(true);
  });

  it("refuses an immature bond without opening the wallet", () => {
    const result = settlementPreflight(bond(), 61_621_717n);
    expect(result.ok).toBe(false);
    if (result.ok) throw new Error("unreachable");
    expect(result.alreadySettled).toBe(false);
    expect(result.reason).toMatch(/matures at block 61621718/);
    expect(result.reason).toMatch(/1 block to go/);
  });

  it("reports an already-settled bond as settled, not as an error", () => {
    const result = settlementPreflight(bond({ state: BondState.Settled }), LIVE_CURRENT_BLOCK);
    expect(result.ok).toBe(false);
    if (result.ok) throw new Error("unreachable");
    expect(result.alreadySettled).toBe(true);
    expect(result.reason).toMatch(/already been settled/i);
  });

  it("refuses a non-finalized bond", () => {
    const result = settlementPreflight(bond({ state: BondState.Provisional }), LIVE_CURRENT_BLOCK);
    expect(result.ok).toBe(false);
  });
});

describe("a successful receipt is final", () => {
  it("stays confirmed when everything after it works", () => {
    expect(
      resolveSettlementOutcome({ receiptSucceeded: true, storageState: BondState.Settled }),
    ).toEqual({ phase: "confirmed", note: "" });
  });

  it("CANNOT become a failure when post-receipt parsing throws", () => {
    const outcome = resolveSettlementOutcome({
      receiptSucceeded: true,
      storageState: undefined,
      postReceiptFailed: true,
    });
    expect(outcome.phase).not.toBe("failed");
    expect(outcome.phase).toBe("confirming");
    expect(outcome.note).toBe("Settlement confirmed. Refreshing bond details…");
  });

  it("CANNOT become a failure when the storage read-back fails", () => {
    const outcome = resolveSettlementOutcome({ receiptSucceeded: true, storageState: undefined });
    expect(outcome.phase).toBe("confirming");
    expect(outcome.note).toMatch(/confirmed/i);
  });

  it("stays confirmed even if storage still reads FINALIZED momentarily", () => {
    // An RPC lagging one block must not turn a mined settlement into a failure.
    const outcome = resolveSettlementOutcome({
      receiptSucceeded: true,
      storageState: BondState.Finalized,
    });
    expect(outcome.phase).toBe("confirmed");
  });
});

describe("storage is the authority", () => {
  it("shows SETTLED from storage even without a receipt of our own", () => {
    // Somebody else settled it: settlement is permissionless.
    const outcome = resolveSettlementOutcome({
      receiptSucceeded: false,
      storageState: BondState.Settled,
    });
    expect(outcome.phase).toBe("confirmed");
  });

  it("beats a stale local FINALIZED record", () => {
    expect(isSettledByStorage(bond({ state: BondState.Settled }))).toBe(true);
    expect(isSettledByStorage(bond({ state: BondState.Finalized }))).toBe(false);
    expect(isSettledByStorage(undefined)).toBe(false);
  });

  it("reports a genuine failure when there is neither a receipt nor settled storage", () => {
    expect(
      resolveSettlementOutcome({ receiptSucceeded: false, storageState: BondState.Finalized }).phase,
    ).toBe("failed");
  });
});

/**
 * The observed browser failure rendered as `reverted with the following reason:` followed by
 * nothing. Every branch below must produce something a person can act on.
 */
describe("custom settlement errors never render empty", () => {
  function revert(data?: { errorName: string; args?: readonly unknown[] }, extra: Record<string, unknown> = {}) {
    const reverted = new ContractFunctionRevertedError({
      abi: [],
      functionName: "settleBond",
    });
    Object.assign(reverted, { data, ...extra });
    const wrapper = new BaseError("The contract function \"settleBond\" reverted.");
    Object.assign(wrapper, { cause: reverted, walk: () => reverted });
    return wrapper;
  }

  it("names a known custom error and explains it", () => {
    const message = describePreflightError(
      revert({ errorName: "BondNotMature", args: ["0xbond", 61_621_718n, 61_621_700n] }),
      "Settlement",
    );
    expect(message).not.toBe("");
    expect(message).toMatch(/BondNotMature/);
    expect(message).toMatch(/maturity block/i);
    expect(message).toMatch(/61621718/);
  });

  it("names a custom error that has no friendly mapping", () => {
    const message = describePreflightError(revert({ errorName: "SomeFutureError" }), "Settlement");
    expect(message).toBe("Settlement failed: SomeFutureError");
  });

  it("reports an UNKNOWN selector rather than an empty reason", () => {
    const message = describePreflightError(revert(undefined, { raw: "0xdeadbeef" }), "Settlement");
    expect(message).toBe("Settlement preflight failed: 0xdeadbeef");
    expect(message).not.toMatch(/reverted with the following reason:\s*$/);
  });

  it("covers the settlement-specific errors from the generated ABI", () => {
    for (const errorName of [
      "BondNotMature",
      "BondNotSettleable",
      "BondNotFound",
      "MaturityCheckpointMissing",
      "SettleBatchTooLarge",
    ]) {
      const message = describePreflightError(revert({ errorName }), "Settlement");
      expect(message.length).toBeGreaterThan(0);
      expect(message).toMatch(new RegExp(errorName));
    }
  });
});
