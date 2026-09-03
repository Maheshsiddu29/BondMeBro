import type { Address, Hex } from "viem";

import { hasRequiredHookPermissions, type Deployment } from "@/lib/deployment";

/**
 * Chain, account and receipt safety.
 *
 * Two things the previous frontend got wrong are fixed here:
 *
 *  1. A render-time "is the wallet on the right network" boolean was treated as a
 *     transaction-time guarantee. It is not. A user can switch account or network in the
 *     middle of a two-step approval, between the moment a button renders and the moment
 *     the next wallet request is created.
 *
 *  2. A mined receipt was treated as a successful one. A reverted transaction is mined.
 */

export type WalletContext = {
  address?: Address;
  chainId?: number;
};

/** The account and chain a flow was started with, captured before the first signature. */
export type IntendedContext = {
  address: Address;
  chainId: number;
};

export type ContextCheck =
  | { ok: true }
  | { ok: false; reason: string; code: "disconnected" | "account-changed" | "chain-changed" };

/**
 * Verifies the live wallet still matches the context this flow was started with.
 *
 * Call this immediately before EVERY write — the token approval, the Permit2 approval, the
 * swap and the settlement — not once at the start. Between two awaited approvals the
 * wallet can have moved.
 */
export function checkContext(intended: IntendedContext, live: WalletContext): ContextCheck {
  if (!live.address || live.chainId === undefined) {
    return { ok: false, reason: "The wallet disconnected. Reconnect and request a new quote.", code: "disconnected" };
  }
  if (live.address.toLowerCase() !== intended.address.toLowerCase()) {
    return {
      ok: false,
      reason: "The wallet account changed during this flow. It was stopped; request a new quote.",
      code: "account-changed",
    };
  }
  if (live.chainId !== intended.chainId) {
    return {
      ok: false,
      reason: "The wallet network changed during this flow. It was stopped; request a new quote.",
      code: "chain-changed",
    };
  }
  return { ok: true };
}

export class ContextChangedError extends Error {
  readonly code: ContextCheck extends { ok: false } ? never : string;
  constructor(check: Extract<ContextCheck, { ok: false }>) {
    super(check.reason);
    this.name = "ContextChangedError";
    this.code = check.code as never;
  }
}

/** Throws unless the live wallet still matches. Used to abort a flow mid-sequence. */
export function assertContext(intended: IntendedContext, live: WalletContext): void {
  const check = checkContext(intended, live);
  if (!check.ok) throw new ContextChangedError(check);
}

export type TradingReadiness =
  | { canTrade: true; deployment: Deployment }
  | { canTrade: false; problems: string[] };

/**
 * Client-side configuration consistency, checked before any transaction is offered.
 *
 * The permission mask is checked as bits. A hook whose low 14 bits are not 0x10C4 cannot be
 * a deployment of this contract, whatever its address happens to look like, and trading is
 * disabled rather than merely warned about.
 */
export function tradingReadiness(deployment: Deployment): TradingReadiness {
  const problems: string[] = [];

  if (!hasRequiredHookPermissions(deployment.hook)) {
    problems.push(
      `Configured hook ${deployment.hook} does not carry the required 0x10C4 permission bits.`,
    );
  }
  if (deployment.currency0.toLowerCase() === deployment.currency1.toLowerCase()) {
    problems.push("The configured pool has the same token on both sides.");
  }

  return problems.length === 0 ? { canTrade: true, deployment } : { canTrade: false, problems };
}

export type ReceiptLike = {
  status: "success" | "reverted";
  transactionHash: Hex;
  blockNumber: bigint;
};

export class TransactionFailedError extends Error {
  readonly transactionHash: Hex;
  constructor(hash: Hex, message: string) {
    super(message);
    this.name = "TransactionFailedError";
    this.transactionHash = hash;
  }
}

/**
 * A mined receipt is not a successful one.
 *
 * Every write in this app passes through here before anything is described as confirmed.
 * The hook can revert for a wrong hookData version, an exceeded collateral ceiling, an
 * immature bond or an already-settled bond, and all of those produce a mined receipt.
 */
export function assertReceiptSucceeded<T extends ReceiptLike>(receipt: T, what: string): T {
  if (receipt.status !== "success") {
    throw new TransactionFailedError(
      receipt.transactionHash,
      `The ${what} transaction was mined but reverted. Nothing was applied.`,
    );
  }
  return receipt;
}

/** A frozen copy of what was actually signed, so later edits cannot rewrite history. */
export type SubmittedSummary = {
  kind: "exactInput" | "exactOutput";
  account: Address;
  chainId: number;
  inputSymbol: string;
  outputSymbol: string;
  /** Exact input: the input amount. Exact output: the maximum total input. */
  primaryAmount: string;
  /** Exact input: the minimum net output. Exact output: the exact output. */
  secondaryAmount: string;
  refundRecipient: Address;
  maxBondAmountLabel: string;
  hookData: Hex;
  submittedAt: number;
};
