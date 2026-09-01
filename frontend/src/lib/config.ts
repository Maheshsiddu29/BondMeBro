import type { Address, Hex } from "viem";

export const sepoliaChainId = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? 11155111);

export const deployment = {
  chainId: sepoliaChainId,
  networkName: process.env.NEXT_PUBLIC_NETWORK_NAME ?? "Sepolia",
  hook: (process.env.NEXT_PUBLIC_HOOK_ADDRESS ?? "0xbFBa0c39308B5b189E8cd0686D3b41A64e8590cC") as Address,
  poolId: (process.env.NEXT_PUBLIC_POOL_ID ?? "0xc8e54122692652e0b9ccad2f46f8bf0f01f4325e544a5dfceb75b0ffd5ea694e") as Hex,
  poolManager: (process.env.NEXT_PUBLIC_POOL_MANAGER ?? "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543") as Address,
  currency0: (process.env.NEXT_PUBLIC_CURRENCY0 ?? "0x0000000000000000000000000000000000000000") as Address,
  currency1: (process.env.NEXT_PUBLIC_CURRENCY1 ?? "0xfff9976782d46CC05630D1f6eBAb18b2324d6B14") as Address,
  poolFee: Number(process.env.NEXT_PUBLIC_POOL_FEE ?? 3000),
  tickSpacing: Number(process.env.NEXT_PUBLIC_TICK_SPACING ?? 60),
} as const;

export const explorerBase = "https://sepolia.etherscan.io";

export function explorerAddress(address: string) {
  return `${explorerBase}/address/${address}`;
}

export function explorerTx(hash: string) {
  return `${explorerBase}/tx/${hash}`;
}

export function shortenHash(value: string, left = 6, right = 4) {
  if (value.length <= left + right + 3) return value;
  return `${value.slice(0, left)}…${value.slice(-right)}`;
}
