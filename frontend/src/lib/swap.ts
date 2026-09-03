import { encodeAbiParameters, encodePacked, type Address, type Hex } from "viem";

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
] as const;

export const erc20Abi = [
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

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
] as const;

const poolKeyType = {
  type: "tuple",
  components: [
    { name: "currency0", type: "address" },
    { name: "currency1", type: "address" },
    { name: "fee", type: "uint24" },
    { name: "tickSpacing", type: "int24" },
    { name: "hooks", type: "address" },
  ],
} as const;

const quoteExactInputSingleType = {
  type: "tuple",
  components: [
    { name: "poolKey", ...poolKeyType },
    { name: "zeroForOne", type: "bool" },
    { name: "exactAmount", type: "uint128" },
    { name: "hookData", type: "bytes" },
  ],
} as const;

/** Canonical Uniswap v4 Sepolia Quoter interface. It returns through a simulated revert. */
export const v4QuoterAbi = [
  {
    type: "function",
    name: "quoteExactInputSingle",
    stateMutability: "nonpayable",
    inputs: [{ name: "params", ...quoteExactInputSingleType }],
    outputs: [{ name: "amountOut", type: "uint256" }, { name: "gasEstimate", type: "uint256" }],
  },
] as const;

const exactInputSingleType = {
  type: "tuple",
  components: [
    { name: "poolKey", ...poolKeyType },
    { name: "zeroForOne", type: "bool" },
    { name: "amountIn", type: "uint128" },
    { name: "amountOutMinimum", type: "uint128" },
    { name: "minHopPriceX36", type: "uint256" },
    { name: "hookData", type: "bytes" },
  ],
} as const;

const settleType = {
  type: "tuple",
  components: [
    { name: "currency", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "payerIsUser", type: "bool" },
  ],
} as const;

const takeType = {
  type: "tuple",
  components: [
    { name: "currency", type: "address" },
    { name: "recipient", type: "address" },
    { name: "amount", type: "uint256" },
  ],
} as const;

/** The fixed BondMeBro hookData wire format: version, recipient, maximum bond. */
export function encodeBondHookData(refundRecipient: Address, maxBondAmount: bigint): Hex {
  return encodePacked(["uint8", "address", "uint128"], [1, refundRecipient, maxBondAmount]);
}

/** Encodes V4Router's SWAP_EXACT_IN_SINGLE + SETTLE + TAKE action plan. */
export function encodeExactInputRouterPlan({
  currency0,
  currency1,
  hooks,
  fee,
  tickSpacing,
  zeroForOne,
  amountIn,
  amountOutMinimum,
  refundRecipient,
  maxBondAmount,
}: {
  currency0: Address;
  currency1: Address;
  hooks: Address;
  fee: number;
  tickSpacing: number;
  zeroForOne: boolean;
  amountIn: bigint;
  amountOutMinimum: bigint;
  refundRecipient: Address;
  maxBondAmount: bigint;
}) {
  const inputCurrency = zeroForOne ? currency0 : currency1;
  const outputCurrency = zeroForOne ? currency1 : currency0;
  const hookData = encodeBondHookData(refundRecipient, maxBondAmount);
  const swapParams = encodeAbiParameters([exactInputSingleType], [{
    poolKey: { currency0, currency1, fee, tickSpacing, hooks },
    zeroForOne,
    amountIn,
    amountOutMinimum,
    minHopPriceX36: 0n,
    hookData,
  }]);
  const settleParams = encodeAbiParameters([settleType], [{ currency: inputCurrency, amount: 0n, payerIsUser: true }]);
  const takeParams = encodeAbiParameters([takeType], [{ currency: outputCurrency, recipient: refundRecipient, amount: 0n }]);
  const actions = "0x060b0e" as Hex;
  // The Universal Router decodes two top-level values: abi.encode(actions, params).
  // Encoding them as one tuple adds an extra offset and causes SliceOutOfBounds().
  const routerInput = encodeAbiParameters(
    [{ type: "bytes" }, { type: "bytes[]" }],
    [actions, [swapParams, settleParams, takeParams]],
  );

  return {
    commands: "0x10" as Hex,
    inputs: [routerInput] as Hex[],
    hookData,
  };
}
