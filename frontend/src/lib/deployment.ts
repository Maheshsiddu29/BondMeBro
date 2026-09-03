import { encodeAbiParameters, isAddress, keccak256, type Address, type Hex } from "viem";

import { poolKeyComponents } from "@/lib/abi/external";

/**
 * The low 14 bits every BondMeBro address must carry.
 *
 * `HOOK_FLAGS` in src/BondMeBro.sol is AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP |
 * AFTER_SWAP_RETURNS_DELTA. `BEFORE_SWAP_RETURNS_DELTA` is deliberately absent, so an
 * address ending in 0x10CC — the value the previous frontend defaulted to — cannot be a
 * deployment of this contract. Checking the bits is the only reliable test; the visible
 * final hex digits of an address are not.
 */
export const REQUIRED_HOOK_PERMISSION_MASK = 0x10c4n;
export const HOOK_PERMISSION_MASK_BITS = 0x3fffn;

export function hookPermissionMask(hook: string): bigint {
  return BigInt(hook) & HOOK_PERMISSION_MASK_BITS;
}

export function hasRequiredHookPermissions(hook: string): boolean {
  try {
    return hookPermissionMask(hook) === REQUIRED_HOOK_PERMISSION_MASK;
  } catch {
    return false;
  }
}

/** One fully specified deployment. Every field is required; there are no defaults. */
export type Deployment = {
  chainId: number;
  networkName: string;
  /** Client reads go through the same-origin proxy; this is the label/link source only. */
  explorerUrl: string;
  hook: Address;
  poolManager: Address;
  universalRouter: Address;
  quoter: Address;
  permit2: Address;
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  poolId: Hex;
  /** First block worth scanning for this hook's logs. */
  deploymentBlock: bigint;
};

export type DeploymentStatus =
  | { status: "ready"; deployment: Deployment }
  | { status: "required"; problems: string[] };

export type RawDeploymentInput = Partial<Record<keyof Deployment, string | undefined>>;

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

/** keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks)) — PoolId.toId(). */
export function computePoolId(key: {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}): Hex {
  return keccak256(
    encodeAbiParameters(poolKeyComponents, [
      key.currency0,
      key.currency1,
      key.fee,
      key.tickSpacing,
      key.hooks,
    ]),
  );
}

function readAddress(problems: string[], label: string, value: string | undefined): Address | undefined {
  if (!value) {
    problems.push(`${label} is not configured.`);
    return undefined;
  }
  if (!isAddress(value)) {
    problems.push(`${label} is not a valid address.`);
    return undefined;
  }
  if (value.toLowerCase() === ZERO_ADDRESS) {
    problems.push(`${label} is the zero address. Native currency is not a supported pool side.`);
    return undefined;
  }
  return value as Address;
}

function readInteger(
  problems: string[],
  label: string,
  value: string | undefined,
  { min, max }: { min: number; max: number },
): number | undefined {
  if (value === undefined || value === "") {
    problems.push(`${label} is not configured.`);
    return undefined;
  }
  if (!/^-?\d+$/.test(value.trim())) {
    problems.push(`${label} must be a whole number.`);
    return undefined;
  }
  const parsed = Number(value.trim());
  if (!Number.isSafeInteger(parsed) || parsed < min || parsed > max) {
    problems.push(`${label} is outside its permitted range.`);
    return undefined;
  }
  return parsed;
}

/**
 * Builds one coherent deployment context, or explains exactly what is missing.
 *
 * Every read and every signed write in the app is bound to the object this returns.
 * There is intentionally no partial mode and no fallback to a previously shipped
 * address: an unverified default is worse than a blank screen, because a successful
 * transaction against the wrong hook looks like a working demo.
 */
export function resolveDeployment(raw: RawDeploymentInput): DeploymentStatus {
  const problems: string[] = [];

  const chainId = readInteger(problems, "Chain ID", raw.chainId, { min: 1, max: Number.MAX_SAFE_INTEGER });
  const hook = readAddress(problems, "Hook address", raw.hook);
  const poolManager = readAddress(problems, "PoolManager address", raw.poolManager);
  const universalRouter = readAddress(problems, "Universal Router address", raw.universalRouter);
  const quoter = readAddress(problems, "Quoter address", raw.quoter);
  const permit2 = readAddress(problems, "Permit2 address", raw.permit2);
  const currency0 = readAddress(problems, "currency0", raw.currency0);
  const currency1 = readAddress(problems, "currency1", raw.currency1);
  const fee = readInteger(problems, "Pool fee", raw.fee, { min: 0, max: 1_000_000 });
  const tickSpacing = readInteger(problems, "Tick spacing", raw.tickSpacing, { min: 1, max: 32_767 });

  let deploymentBlock: bigint | undefined;
  if (raw.deploymentBlock === undefined || raw.deploymentBlock === "") {
    problems.push("Deployment block is not configured. Log discovery needs a starting block.");
  } else if (!/^\d+$/.test(raw.deploymentBlock.trim())) {
    problems.push("Deployment block must be a whole number.");
  } else {
    deploymentBlock = BigInt(raw.deploymentBlock.trim());
  }

  if (hook && !hasRequiredHookPermissions(hook)) {
    problems.push(
      `Hook ${hook} has permission bits 0x${hookPermissionMask(hook)
        .toString(16)
        .toUpperCase()}, but this contract requires 0x10C4. It is not a deployment of this source.`,
    );
  }

  if (currency0 && currency1) {
    if (currency0.toLowerCase() === currency1.toLowerCase()) {
      problems.push("currency0 and currency1 are the same token.");
    } else if (BigInt(currency0) > BigInt(currency1)) {
      problems.push("currency0 must sort below currency1, as Uniswap v4 orders a PoolKey.");
    }
  }

  const networkName = raw.networkName?.trim();
  if (!networkName) problems.push("Network name is not configured.");

  const explorerUrl = raw.explorerUrl?.trim().replace(/\/+$/, "");
  if (!explorerUrl) problems.push("Explorer URL is not configured.");
  else if (!/^https:\/\/\S+$/.test(explorerUrl)) problems.push("Explorer URL must be an https URL.");

  if (
    chainId === undefined
    || hook === undefined
    || poolManager === undefined
    || universalRouter === undefined
    || quoter === undefined
    || permit2 === undefined
    || currency0 === undefined
    || currency1 === undefined
    || fee === undefined
    || tickSpacing === undefined
    || deploymentBlock === undefined
    || !networkName
    || !explorerUrl
    || problems.length > 0
  ) {
    return { status: "required", problems: problems.length > 0 ? problems : ["Deployment is incomplete."] };
  }

  const poolId = computePoolId({ currency0, currency1, fee, tickSpacing, hooks: hook });

  // A supplied pool ID is treated as an assertion to check, never as the source of truth:
  // the ID is a pure function of the key, so a mismatch means the key is wrong.
  const declaredPoolId = raw.poolId?.trim();
  if (declaredPoolId && declaredPoolId.toLowerCase() !== poolId.toLowerCase()) {
    return {
      status: "required",
      problems: [
        `Configured pool ID ${declaredPoolId} does not match the ID derived from the configured PoolKey (${poolId}).`,
      ],
    };
  }

  return {
    status: "ready",
    deployment: {
      chainId,
      networkName,
      explorerUrl,
      hook,
      poolManager,
      universalRouter,
      quoter,
      permit2,
      currency0,
      currency1,
      fee,
      tickSpacing,
      poolId,
      deploymentBlock,
    },
  };
}

/**
 * The deployment this build was configured with.
 *
 * Next.js inlines `process.env.NEXT_PUBLIC_*` at build time only when each name is written
 * out literally, so these cannot be looped over.
 */
export const deploymentStatus: DeploymentStatus = resolveDeployment({
  chainId: process.env.NEXT_PUBLIC_CHAIN_ID,
  networkName: process.env.NEXT_PUBLIC_NETWORK_NAME,
  explorerUrl: process.env.NEXT_PUBLIC_EXPLORER_URL,
  hook: process.env.NEXT_PUBLIC_HOOK_ADDRESS,
  poolManager: process.env.NEXT_PUBLIC_POOL_MANAGER,
  universalRouter: process.env.NEXT_PUBLIC_UNIVERSAL_ROUTER,
  quoter: process.env.NEXT_PUBLIC_QUOTER,
  permit2: process.env.NEXT_PUBLIC_PERMIT2,
  currency0: process.env.NEXT_PUBLIC_CURRENCY0,
  currency1: process.env.NEXT_PUBLIC_CURRENCY1,
  fee: process.env.NEXT_PUBLIC_POOL_FEE,
  tickSpacing: process.env.NEXT_PUBLIC_TICK_SPACING,
  poolId: process.env.NEXT_PUBLIC_POOL_ID,
  deploymentBlock: process.env.NEXT_PUBLIC_DEPLOYMENT_BLOCK,
});

export function explorerAddress(deployment: Deployment, address: string) {
  return `${deployment.explorerUrl}/address/${address}`;
}

export function explorerTx(deployment: Deployment, hash: string) {
  return `${deployment.explorerUrl}/tx/${hash}`;
}

export function shortenHash(value: string, left = 6, right = 4) {
  if (value.length <= left + right + 3) return value;
  return `${value.slice(0, left)}…${value.slice(-right)}`;
}

export function poolKeyOf(deployment: Deployment) {
  return {
    currency0: deployment.currency0,
    currency1: deployment.currency1,
    fee: deployment.fee,
    tickSpacing: deployment.tickSpacing,
    hooks: deployment.hook,
  } as const;
}
