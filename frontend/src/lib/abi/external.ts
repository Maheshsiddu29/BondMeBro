// Minimal ABIs for the contracts BondMeBro is used *through*: the ERC20s of the pool,
// Permit2, the Universal Router and the v4 Quoter.
//
// These are transcribed from the versions installed under lib/ at the current contract
// baseline (v4-periphery dce236d4, its v4-core 59d3ecf5), not from memory:
//   - IV4Router.ExactInputSingleParams / ExactOutputSingleParams: lib/v4-periphery/src/interfaces/IV4Router.sol
//     (MINUS `minHopPriceX36`, which the deployed router predates — see the note on the
//      tuple definitions below; the deployed shape wins over the pinned one)
//   - IV4Quoter.QuoteExactSingleParams:                            lib/v4-periphery/src/interfaces/IV4Quoter.sol
//   - Action bytes:                                                lib/v4-periphery/src/libraries/Actions.sol
import type { Abi } from "viem";

export const erc20Abi = [
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
  {
    type: "function",
    name: "symbol",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
] as const satisfies Abi;

export const permit2Abi = [
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "spender", type: "address" },
      { name: "amount", type: "uint160" },
      { name: "expiration", type: "uint48" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "token", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [
      { name: "amount", type: "uint160" },
      { name: "expiration", type: "uint48" },
      { name: "nonce", type: "uint48" },
    ],
  },
] as const satisfies Abi;

export const universalRouterAbi = [
  {
    type: "function",
    name: "execute",
    stateMutability: "payable",
    inputs: [
      { name: "commands", type: "bytes" },
      { name: "inputs", type: "bytes[]" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [],
  },
] as const satisfies Abi;

export const poolKeyComponents = [
  { name: "currency0", type: "address" },
  { name: "currency1", type: "address" },
  { name: "fee", type: "uint24" },
  { name: "tickSpacing", type: "int24" },
  { name: "hooks", type: "address" },
] as const;

const quoteExactSingleParams = {
  type: "tuple",
  components: [
    { name: "poolKey", type: "tuple", components: poolKeyComponents },
    { name: "zeroForOne", type: "bool" },
    { name: "exactAmount", type: "uint128" },
    { name: "hookData", type: "bytes" },
  ],
} as const;

/**
 * V4Quoter. Both entry points return through a simulated revert, so they are declared
 * `nonpayable` and must be reached with a simulation, never a signed transaction.
 *
 * For an exact-input quote the result is the NET output, already reduced by the
 * collateral the hook would take at quote-time pool state. For an exact-output quote
 * the result is the TOTAL input, already including that collateral.
 */
export const v4QuoterAbi = [
  {
    type: "function",
    name: "quoteExactInputSingle",
    stateMutability: "nonpayable",
    inputs: [{ name: "params", ...quoteExactSingleParams }],
    outputs: [
      { name: "amountOut", type: "uint256" },
      { name: "gasEstimate", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "quoteExactOutputSingle",
    stateMutability: "nonpayable",
    inputs: [{ name: "params", ...quoteExactSingleParams }],
    outputs: [
      { name: "amountIn", type: "uint256" },
      { name: "gasEstimate", type: "uint256" },
    ],
  },
] as const satisfies Abi;

/**
 * THE DEPLOYED ROUTER'S SWAP PARAMETERS, WHICH ARE NOT THE PINNED ONES.
 *
 * `IV4Router.ExactInputSingleParams` in the v4-periphery pinned in this repository carries a
 * `minHopPriceX36` field between `amountOutMinimum` and `hookData`. The Universal Router
 * deployed on Unichain Sepolia at 0x7f9b8d606e0f35e5073abf93695814530b28a37b was built
 * against an EARLIER v4-periphery that has no such field.
 *
 * Its calldata decoder is strict. An extra word shifts the `hookData` offset, and the call
 * reverts inside `unlockCallback` before any swap happens — with no revert reason, which
 * makes it an expensive thing to debug from the browser.
 *
 * This was established empirically against a Unichain Sepolia fork in
 * `test/fork/DemoPoolForkRehearsal.t.sol`: encoding the pinned struct reverts, encoding this
 * one swaps successfully. Do NOT "restore" the field to match the pinned interface without
 * first proving the deployed router accepts it; `abi/external.test.ts` fails if it comes
 * back.
 */
export const exactInputSingleParamsType = {
  type: "tuple",
  components: [
    { name: "poolKey", type: "tuple", components: poolKeyComponents },
    { name: "zeroForOne", type: "bool" },
    { name: "amountIn", type: "uint128" },
    { name: "amountOutMinimum", type: "uint128" },
    { name: "hookData", type: "bytes" },
  ],
} as const;

/** The deployed router's ExactOutputSingleParams. See the note above on `minHopPriceX36`. */
export const exactOutputSingleParamsType = {
  type: "tuple",
  components: [
    { name: "poolKey", type: "tuple", components: poolKeyComponents },
    { name: "zeroForOne", type: "bool" },
    { name: "amountOut", type: "uint128" },
    { name: "amountInMaximum", type: "uint128" },
    { name: "hookData", type: "bytes" },
  ],
} as const;

export const settleParamsType = {
  type: "tuple",
  components: [
    { name: "currency", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "payerIsUser", type: "bool" },
  ],
} as const;

export const takeParamsType = {
  type: "tuple",
  components: [
    { name: "currency", type: "address" },
    { name: "recipient", type: "address" },
    { name: "amount", type: "uint256" },
  ],
} as const;

/** Actions.sol byte values used by the two single-hop plans this app can build. */
export const ROUTER_ACTIONS = {
  SWAP_EXACT_IN_SINGLE: 0x06,
  SWAP_EXACT_OUT_SINGLE: 0x08,
  SETTLE: 0x0b,
  TAKE: 0x0e,
} as const;

/** UniversalRouter command byte for a V4 swap plan. */
export const V4_SWAP_COMMAND = "0x10" as const;

/**
 * ActionConstants.OPEN_DELTA. A zero settle amount pays the whole outstanding debt and a
 * zero take amount withdraws the whole credit, which is what both plans want: the exact
 * figures are only known after the hook has taken its collateral.
 */
export const OPEN_DELTA = 0n;
