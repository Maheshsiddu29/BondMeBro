import { BaseError, ContractFunctionRevertedError } from "viem";

import { GasEstimateError } from "@/lib/gas";
import { ContextChangedError, TransactionFailedError } from "@/lib/guards";
import { HookDataError } from "@/lib/hookData";
import { LimitError } from "@/lib/limits";

/**
 * Turns a failure into something a user can act on.
 *
 * The names matched here are the CURRENT contract's custom errors, taken from the compiled
 * ABI. The old frontend still checked for `BondSlippage`, donation and claim errors that no
 * longer exist, so every real revert fell through to one generic sentence.
 */
const CONTRACT_ERRORS: { match: string; message: string }[] = [
  {
    match: "unsupportedhookdataversion",
    message:
      "The hook rejected this swap's attached data version. The app and the deployed contract disagree; do not retry until the deployment is verified.",
  },
  {
    match: "invalidhookdatalength",
    message: "The hook rejected the attached data's length. This is an integration fault, not a wallet problem.",
  },
  { match: "missinghookdata", message: "This pool requires a refund recipient and collateral ceiling on the swap." },
  {
    match: "zerorefundrecipient",
    message: "The refund recipient was empty. Reconnect the wallet and request a new quote.",
  },
  { match: "zeromaxbondamount", message: "The collateral ceiling was zero. Request a new quote." },
  {
    match: "bondexceedstradermax",
    message:
      "The refundable collateral for this execution exceeded the ceiling you approved. Another trade moved the pool in your block; request a new quote.",
  },
  {
    match: "bondviolatesnoopvlbound",
    message: "The hook refused a collateral amount outside its safety bound. Nothing was taken.",
  },
  { match: "bondnotfound", message: "No such bond exists." },
  { match: "bondnotmature", message: "This bond has not reached its maturity block yet." },
  {
    match: "bondnotsettleable",
    message: "This bond is not in a settleable state. It may already have been settled by someone else.",
  },
  { match: "maturitycheckpointmissing", message: "The pool's maturity checkpoint for this bond is not recorded yet." },
  { match: "settlebatchtoolarge", message: "Too many bonds were sent in one settlement batch." },
  { match: "poolnotregistered", message: "This pool has not been initialised with the hook." },
  { match: "incompletebondingconfig", message: "Enabling bonding requires both input minimums to be above zero." },
  {
    match: "variablelegminimumtoosmall",
    message: "Both variable-leg minimums must be at least 10,000 raw units of their own currency.",
  },
  { match: "notowner", message: "Only the hook owner can change a pool's configuration." },
  // Router-side bounds.
  {
    match: "v4toolittlereceived",
    message: "The swap would have delivered less than your minimum output. Nothing was swapped.",
  },
  {
    match: "v4toomuchrequested",
    message: "The swap would have spent more than your maximum input. Nothing was swapped.",
  },
  { match: "v4exactoutputunfilled", message: "The pool could not deliver the exact output requested." },
];

export function describeError(error: unknown): string {
  if (error instanceof ContextChangedError) return error.message;
  if (error instanceof TransactionFailedError) return error.message;
  if (error instanceof GasEstimateError) return error.message;
  if (error instanceof HookDataError) return `Swap data could not be prepared: ${error.message}`;
  if (error instanceof LimitError) return `Swap limits could not be prepared: ${error.message}`;

  const message = error instanceof Error ? error.message : String(error);
  const lower = message.toLowerCase();

  if (lower.includes("user rejected") || lower.includes("user denied")) {
    return "The wallet rejected this request. Nothing was submitted.";
  }
  if (lower.includes("transaction was replaced") || lower.includes("replacementnotfound")) {
    return "This transaction was replaced or cancelled in the wallet. Check the wallet's history before retrying.";
  }
  if (lower.includes("chain mismatch") || lower.includes("chain of the connector")) {
    return "The wallet is on a different network from the one this app is configured for.";
  }
  if (lower.includes("insufficient funds") || lower.includes("insufficient balance")) {
    return "The wallet does not have enough balance for this transaction and its gas.";
  }

  for (const entry of CONTRACT_ERRORS) {
    if (lower.includes(entry.match)) return entry.message;
  }

  if (lower.includes("notenoughliquidity") || lower.includes("no liquidity")) {
    return "This pool does not have enough liquidity for that size.";
  }

  // Keep the first line of the underlying message: a generic sentence with the details
  // hidden in a console the user will not open is worse than a slightly technical one.
  const firstLine = message.split("\n")[0]?.trim();
  return firstLine ? `The transaction could not be completed: ${firstLine}` : "The transaction could not be completed.";
}

export function isLiquidityError(error: unknown): boolean {
  const message = (error instanceof Error ? error.message : String(error)).toLowerCase();
  return (
    message.includes("notenoughliquidity")
    || message.includes("insufficient liquidity")
    || message.includes("no liquidity")
  );
}

/**
 * Decodes a revert from a preflight simulation into something a person can act on.
 *
 * viem reports an undecodable revert as `reverted with the following reason:` followed by
 * nothing, which tells the user precisely as much as silence. Because the generated ABI
 * carries every current custom error, a known revert decodes to its real name and arguments;
 * an unknown one is reported by selector so it can at least be looked up.
 *
 * @param error Thrown by `estimateContractGas` or `simulateContract`.
 * @param what Short noun for the operation, e.g. "Settlement".
 */
export function describePreflightError(error: unknown, what: string): string {
  if (error instanceof BaseError) {
    const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);

    if (reverted instanceof ContractFunctionRevertedError) {
      // A custom error the generated ABI knows about.
      if (reverted.data?.errorName) {
        const args = reverted.data.args ?? [];
        const rendered = args.length > 0 ? ` (${args.map((a) => String(a)).join(", ")})` : "";
        const known = CONTRACT_ERRORS.find((entry) =>
          reverted.data?.errorName?.toLowerCase().includes(entry.match),
        );
        return known
          ? `${known.message} [${reverted.data.errorName}${rendered}]`
          : `${what} failed: ${reverted.data.errorName}${rendered}`;
      }

      // A plain string revert.
      if (reverted.reason) return `${what} failed: ${reverted.reason}`;

      // Unknown selector: report it rather than an empty reason.
      const raw = reverted.signature ?? reverted.raw;
      if (raw) return `${what} preflight failed: ${raw}`;
    }
  }

  return describeError(error);
}
