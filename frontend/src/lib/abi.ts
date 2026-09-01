import type { Abi } from "viem";

/** Read/event surface used by the dashboard. Keep this subset synchronized with src/BondMeBro.sol. */
export const bondMeBroAbi = [
  { type: "function", name: "poolManager", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { type: "function", name: "owner", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { type: "function", name: "bondBps", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint16" }] },
  { type: "function", name: "refundTolTicks", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint24" }] },
  { type: "function", name: "observationBlocks", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint32" }] },
  { type: "function", name: "maxAbsTickDelta", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint24" }] },
  { type: "function", name: "settlerFeeBps", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint16" }] },
  { type: "function", name: "maxSettlesPerSwap", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "uint8" }] },
  {
    type: "function", name: "getPoolConfig", stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [{ name: "", type: "tuple", components: [
      { name: "minBondedAmount0", type: "uint96" },
      { name: "minBondedAmount1", type: "uint96" },
      { name: "bondBps", type: "uint16" },
    ] }],
  },
  { type: "function", name: "queueLength", stateMutability: "view", inputs: [{ name: "id", type: "bytes32" }], outputs: [{ name: "length", type: "uint256" }] },
  {
    type: "function", name: "queueBounds", stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [{ name: "head", type: "bytes32" }, { name: "tail", type: "bytes32" }],
  },
  {
    type: "function", name: "getBond", stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }, { name: "bondId", type: "bytes32" }],
    outputs: [{ name: "", type: "tuple", components: [
      { name: "owner", type: "address" },
      { name: "openBlock", type: "uint48" },
      { name: "tickBefore", type: "int24" },
      { name: "tickAfter", type: "int24" },
      { name: "currency", type: "address" },
      { name: "cumulativeAtOpen", type: "int56" },
      { name: "amount", type: "uint128" },
      { name: "next", type: "bytes32" },
    ] }],
  },
  {
    type: "function", name: "getAccumulator", stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [{ name: "", type: "tuple", components: [
      { name: "lastTick", type: "int24" },
      { name: "lastUpdate", type: "uint48" },
      { name: "tickCumulative", type: "int56" },
    ] }],
  },
  { type: "function", name: "insurancePot", stateMutability: "view", inputs: [{ name: "", type: "bytes32" }, { name: "", type: "address" }], outputs: [{ name: "", type: "uint256" }] },
  {
    type: "event", name: "BondOpened", anonymous: false,
    inputs: [
      { indexed: true, name: "poolId", type: "bytes32" }, { indexed: true, name: "bondId", type: "bytes32" },
      { indexed: true, name: "owner", type: "address" }, { indexed: false, name: "currency", type: "address" },
      { indexed: false, name: "amount", type: "uint128" }, { indexed: false, name: "tickBefore", type: "int24" },
      { indexed: false, name: "tickAfter", type: "int24" }, { indexed: false, name: "maturesAtBlock", type: "uint48" },
    ],
  },
  {
    type: "event", name: "BondSettled", anonymous: false,
    inputs: [
      { indexed: true, name: "poolId", type: "bytes32" }, { indexed: true, name: "bondId", type: "bytes32" },
      { indexed: true, name: "owner", type: "address" }, { indexed: false, name: "settler", type: "address" },
      { indexed: false, name: "refundAmount", type: "uint128" }, { indexed: false, name: "slashAmount", type: "uint128" },
      { indexed: false, name: "settlerFee", type: "uint128" }, { indexed: false, name: "twaReference", type: "int24" },
      { indexed: false, name: "persistenceBps", type: "uint16" },
    ],
  },
  {
    type: "event", name: "PoolConfigUpdated", anonymous: false,
    inputs: [
      { indexed: true, name: "poolId", type: "bytes32" }, { indexed: false, name: "minBondedAmount0", type: "uint96" },
      { indexed: false, name: "minBondedAmount1", type: "uint96" }, { indexed: false, name: "bondBps", type: "uint16" },
      { indexed: true, name: "caller", type: "address" },
    ],
  },
  {
    type: "event", name: "PotDonated", anonymous: false,
    inputs: [
      { indexed: true, name: "poolId", type: "bytes32" }, { indexed: true, name: "currency", type: "address" },
      { indexed: false, name: "amount", type: "uint256" }, { indexed: false, name: "caller", type: "address" },
    ],
  },
] as const satisfies Abi;

export type BondMeBroAbi = typeof bondMeBroAbi;
