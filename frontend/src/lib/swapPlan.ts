import { encodeAbiParameters, encodePacked, type Address, type Hex } from "viem";

import {
  exactInputSingleParamsType,
  exactOutputSingleParamsType,
  OPEN_DELTA,
  ROUTER_ACTIONS,
  settleParamsType,
  takeParamsType,
  V4_SWAP_COMMAND,
} from "@/lib/abi/external";
import type { Deployment } from "@/lib/deployment";
import { encodeHookData } from "@/lib/hookData";
import type { SwapKind } from "@/lib/poolConfig";

export type RouterPlan = {
  commands: Hex;
  inputs: Hex[];
  hookData: Hex;
  actions: Hex;
};

function poolKeyOf(deployment: Deployment) {
  return {
    currency0: deployment.currency0,
    currency1: deployment.currency1,
    fee: deployment.fee,
    tickSpacing: deployment.tickSpacing,
    hooks: deployment.hook,
  } as const;
}

/**
 * The Universal Router decodes its V4_SWAP input as two top-level values,
 * `abi.encode(actions, params)`. Wrapping them in one tuple adds an extra offset word and
 * the router reverts with SliceOutOfBounds.
 */
function encodeRouterInput(actions: Hex, params: Hex[]): Hex {
  return encodeAbiParameters([{ type: "bytes" }, { type: "bytes[]" }], [actions, params]);
}

/**
 * Exact input: SWAP_EXACT_IN_SINGLE, SETTLE the input debt, TAKE the output credit.
 *
 * The user's specified input is passed through untouched — the hook does not carve
 * anything out of it. Collateral is withheld from the realized output, so `amountOutMinimum`
 * is checked against the NET receipt and is the user's protection. `maxBondAmount` is the
 * uint128 maximum; see lib/hookData.ts for why a quote-derived ceiling is unsafe here.
 *
 * Both settle and take use OPEN_DELTA (zero), meaning "the whole debt" and "the whole
 * credit". The exact figures are not known until the hook has taken its collateral.
 */
export function buildExactInputPlan({
  deployment,
  zeroForOne,
  amountIn,
  amountOutMinimum,
  refundRecipient,
  recipient,
  maxBondAmount,
}: {
  deployment: Deployment;
  zeroForOne: boolean;
  amountIn: bigint;
  amountOutMinimum: bigint;
  /** Address entitled to the future refund. Comes only from hookData. */
  refundRecipient: Address;
  /** Address the swap output is delivered to. */
  recipient: Address;
  maxBondAmount: bigint;
}): RouterPlan {
  const inputCurrency = zeroForOne ? deployment.currency0 : deployment.currency1;
  const outputCurrency = zeroForOne ? deployment.currency1 : deployment.currency0;
  const hookData = encodeHookData({ refundRecipient, maxBondAmount });

  const swap = encodeAbiParameters(
    [exactInputSingleParamsType],
    [
      {
        poolKey: poolKeyOf(deployment),
        zeroForOne,
        amountIn,
        amountOutMinimum,
        hookData,
      },
    ],
  );
  const settle = encodeAbiParameters(
    [settleParamsType],
    [{ currency: inputCurrency, amount: OPEN_DELTA, payerIsUser: true }],
  );
  const take = encodeAbiParameters(
    [takeParamsType],
    [{ currency: outputCurrency, recipient, amount: OPEN_DELTA }],
  );

  const actions = encodePacked(
    ["uint8", "uint8", "uint8"],
    [ROUTER_ACTIONS.SWAP_EXACT_IN_SINGLE, ROUTER_ACTIONS.SETTLE, ROUTER_ACTIONS.TAKE],
  );

  return {
    commands: V4_SWAP_COMMAND,
    inputs: [encodeRouterInput(actions, [swap, settle, take])],
    hookData,
    actions,
  };
}

/**
 * Exact output: SWAP_EXACT_OUT_SINGLE, SETTLE the input debt, TAKE the output credit.
 *
 * The specified output is unchanged by collateral; the collateral is ADDITIONAL input, so
 * the total spend is poolInput + collateral. `amountInMaximum` is the bound the user
 * approves and must be derived from the hook's own constants — see lib/limits.ts.
 *
 * The SETTLE amount is again OPEN_DELTA so the router pays the whole final input debt,
 * which is exactly what `amountInMaximum` caps. A fixed settle amount would either
 * underpay or overpay once the hook's collateral is applied.
 */
export function buildExactOutputPlan({
  deployment,
  zeroForOne,
  amountOut,
  amountInMaximum,
  refundRecipient,
  recipient,
  maxBondAmount,
}: {
  deployment: Deployment;
  zeroForOne: boolean;
  amountOut: bigint;
  amountInMaximum: bigint;
  refundRecipient: Address;
  recipient: Address;
  maxBondAmount: bigint;
}): RouterPlan {
  const inputCurrency = zeroForOne ? deployment.currency0 : deployment.currency1;
  const outputCurrency = zeroForOne ? deployment.currency1 : deployment.currency0;
  const hookData = encodeHookData({ refundRecipient, maxBondAmount });

  const swap = encodeAbiParameters(
    [exactOutputSingleParamsType],
    [
      {
        poolKey: poolKeyOf(deployment),
        zeroForOne,
        amountOut,
        amountInMaximum,
        hookData,
      },
    ],
  );
  const settle = encodeAbiParameters(
    [settleParamsType],
    [{ currency: inputCurrency, amount: OPEN_DELTA, payerIsUser: true }],
  );
  const take = encodeAbiParameters(
    [takeParamsType],
    [{ currency: outputCurrency, recipient, amount: OPEN_DELTA }],
  );

  const actions = encodePacked(
    ["uint8", "uint8", "uint8"],
    [ROUTER_ACTIONS.SWAP_EXACT_OUT_SINGLE, ROUTER_ACTIONS.SETTLE, ROUTER_ACTIONS.TAKE],
  );

  return {
    commands: V4_SWAP_COMMAND,
    inputs: [encodeRouterInput(actions, [swap, settle, take])],
    hookData,
    actions,
  };
}

/** The token the wallet must hold and approve, and the amount that must be covered. */
export function spendRequirement({
  deployment,
  kind,
  zeroForOne,
  amountIn,
  amountInMaximum,
}: {
  deployment: Deployment;
  kind: SwapKind;
  zeroForOne: boolean;
  amountIn?: bigint;
  amountInMaximum?: bigint;
}): { currency: Address; amount: bigint } | undefined {
  const currency = zeroForOne ? deployment.currency0 : deployment.currency1;
  // Exact output must cover the total maximum, which includes refundable collateral.
  const amount = kind === "exactInput" ? amountIn : amountInMaximum;
  if (amount === undefined || amount <= 0n) return undefined;
  return { currency, amount };
}
