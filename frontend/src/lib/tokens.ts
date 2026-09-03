import type { Address } from "viem";

export type TokenOption = {
  symbol: string;
  name: string;
  address: Address;
  decimals: number;
  icon: string;
  kind: "native" | "erc20";
};

export const sepoliaTokens = {
  ETH: {
    symbol: "ETH",
    name: "Sepolia Ether",
    address: "0x0000000000000000000000000000000000000000" as Address,
    decimals: 18,
    icon: "Ξ",
    kind: "native",
  },
  WETH: {
    symbol: "WETH",
    name: "Wrapped Ether",
    address: "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14" as Address,
    decimals: 18,
    icon: "W",
    kind: "erc20",
  },
  USDC: {
    symbol: "USDC",
    name: "USD Coin",
    address: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238" as Address,
    decimals: 6,
    icon: "$",
    kind: "erc20",
  },
  LINK: {
    symbol: "LINK",
    name: "Chainlink Token",
    address: "0x779877A7B0D9E8603169DdbD7836e478b4624789" as Address,
    decimals: 18,
    icon: "L",
    kind: "erc20",
  },
  DAI: {
    symbol: "DAI",
    name: "Dai Stablecoin",
    address: "0x68194a729C2450ad26072b3D33ADaCbcef39D574" as Address,
    decimals: 18,
    icon: "D",
    kind: "erc20",
  },
} satisfies Record<string, TokenOption>;

export const tokenOptions = Object.values(sepoliaTokens);

export function isConfiguredPair(pay: TokenOption, receive: TokenOption, currency0: Address, currency1: Address) {
  const payAddress = pay.address.toLowerCase();
  const receiveAddress = receive.address.toLowerCase();
  const first = currency0.toLowerCase();
  const second = currency1.toLowerCase();
  return (payAddress === first && receiveAddress === second) || (payAddress === second && receiveAddress === first);
}
