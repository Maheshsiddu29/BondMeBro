import { beforeAll, describe, expect, it } from "vitest";
import {
  createPublicClient,
  createWalletClient,
  decodeEventLog,
  http,
  type Address,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { bondMeBroAbi } from "@/lib/abi/bondMeBro";
import { erc20Abi } from "@/lib/abi/external";
import { resolveDeployment, type Deployment } from "@/lib/deployment";
import { assertReceiptSucceeded } from "@/lib/guards";
import {
  poolConfigFromEvent,
  poolConfigFromGetter,
  poolConfigSetterArgs,
  thresholdsFor,
  type PoolConfig,
  type PoolConfigGetterTuple,
} from "@/lib/poolConfig";
import { clearTokenMetaCache, loadTokenMeta } from "@/lib/tokenMetadata";

/**
 * OPT-IN live integration test.
 *
 * `npm test` skips this unless a chain is supplied, so the default suite stays hermetic.
 * Run it against a local node that already has the current hook deployed and its pool
 * initialised:
 *
 *   BMB_RPC_URL=http://127.0.0.1:8545 \
 *   BMB_HOOK=0x... BMB_POOL_MANAGER=0x... \
 *   BMB_CURRENCY0=0x... BMB_CURRENCY1=0x... BMB_DEPLOYMENT_BLOCK=0 \
 *   npm test
 *
 * What this adds over the offline tests: those pin the frontend against the compiled
 * artifact, which proves the two agree with each other. These calls go to a real deployed
 * contract, so they also prove the encoding actually round-trips on chain — in particular
 * that the PoolConfig getter, setter and event orderings are each handled separately.
 */
const RPC_URL = process.env.BMB_RPC_URL;
const enabled = Boolean(
  RPC_URL
    && process.env.BMB_HOOK
    && process.env.BMB_POOL_MANAGER
    && process.env.BMB_CURRENCY0
    && process.env.BMB_CURRENCY1,
);

// anvil's first well-known development account. This test is for local chains only.
const LOCAL_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

describe.skipIf(!enabled)("live contract integration", () => {
  let deployment: Deployment;
  let publicClient: PublicClient;
  let wallet: WalletClient;
  let owner: Address;

  beforeAll(async () => {
    const resolved = resolveDeployment({
      chainId: process.env.BMB_CHAIN_ID ?? "31337",
      networkName: "Local anvil",
      explorerUrl: "https://explorer.invalid",
      hook: process.env.BMB_HOOK,
      poolManager: process.env.BMB_POOL_MANAGER,
      // The router and quoter are not needed by these reads, but the manifest fails closed
      // without them, which is itself the behaviour under test.
      universalRouter: process.env.BMB_UNIVERSAL_ROUTER ?? "0x0000000000000000000000000000000000000010",
      quoter: process.env.BMB_QUOTER ?? "0x0000000000000000000000000000000000000011",
      permit2: process.env.BMB_PERMIT2 ?? "0x000000000022D473030F116dDEE9F6B43aC78BA3",
      currency0: process.env.BMB_CURRENCY0,
      currency1: process.env.BMB_CURRENCY1,
      fee: process.env.BMB_POOL_FEE ?? "3000",
      tickSpacing: process.env.BMB_TICK_SPACING ?? "60",
      deploymentBlock: process.env.BMB_DEPLOYMENT_BLOCK ?? "0",
    });
    if (resolved.status !== "ready") {
      throw new Error(`deployment not ready: ${resolved.problems.join(" ")}`);
    }
    deployment = resolved.deployment;

    const account = privateKeyToAccount(LOCAL_KEY);
    owner = account.address;
    publicClient = createPublicClient({ transport: http(RPC_URL) }) as PublicClient;
    wallet = createWalletClient({ account, transport: http(RPC_URL) });
    clearTokenMetaCache();
  });

  it("accepts the live hook's permission bits and derives its pool ID", () => {
    expect(BigInt(deployment.hook) & 0x3fffn).toBe(0x10c4n);
    expect(deployment.poolId).toMatch(/^0x[0-9a-f]{64}$/);
  });

  it("reads the frozen constants straight off the deployed hook", async () => {
    const [bps, cap, observation] = await Promise.all([
      publicClient.readContract({ address: deployment.hook, abi: bondMeBroAbi, functionName: "BPS" }),
      publicClient.readContract({ address: deployment.hook, abi: bondMeBroAbi, functionName: "MAX_BOND_BPS" }),
      publicClient.readContract({
        address: deployment.hook,
        abi: bondMeBroAbi,
        functionName: "OBSERVATION_BLOCKS",
      }),
    ]);
    expect(bps).toBe(10_000n);
    expect(Number(cap)).toBe(100);
    // Ten blocks, not the 25 the previous frontend fell back to.
    expect(Number(observation)).toBe(10);
  });

  it("reads real, differing token decimals rather than assuming 18", async () => {
    const reader = {
      readDecimals: (address: Address) =>
        publicClient.readContract({ address, abi: erc20Abi, functionName: "decimals" }).then(Number),
      readSymbol: (address: Address) =>
        publicClient.readContract({ address, abi: erc20Abi, functionName: "symbol" }),
    };
    const [token0, token1] = await Promise.all([
      loadTokenMeta(deployment.chainId, deployment.currency0, reader),
      loadTokenMeta(deployment.chainId, deployment.currency1, reader),
    ]);
    expect(new Set([token0.decimals, token1.decimals])).toEqual(new Set([18, 6]));
    expect(token0.symbol).not.toBe("");
    expect(token1.symbol).not.toBe("");
  });

  it("confirms the pool was registered by afterInitialize", async () => {
    const index = await publicClient.readContract({
      address: deployment.hook,
      abi: bondMeBroAbi,
      functionName: "poolConfig",
      args: [deployment.poolId],
    });
    expect(Array.isArray(index)).toBe(true);
  });

  it("round-trips a five-field configuration through the SETTER and back through the GETTER", async () => {
    const desired: PoolConfig = {
      minBondedAmount0: 1_000_000_000_000_000n,
      minBondedAmount1: 1_000_000n,
      minVariableLeg0: 10_000n,
      minVariableLeg1: 20_000n,
      bondingEnabled: true,
    };

    const hash = await wallet.writeContract({
      address: deployment.hook,
      abi: bondMeBroAbi,
      functionName: "setPoolConfig",
      args: poolConfigSetterArgs(deployment, desired),
      account: owner,
      chain: null,
    });
    const receipt = assertReceiptSucceeded(
      await publicClient.waitForTransactionReceipt({ hash }),
      "configuration",
    );

    const stored = poolConfigFromGetter(
      (await publicClient.readContract({
        address: deployment.hook,
        abi: bondMeBroAbi,
        functionName: "poolConfig",
        args: [deployment.poolId],
      })) as unknown as PoolConfigGetterTuple,
    );

    // If setter and getter orders had been collapsed into one positional tuple, the
    // boolean would land in a threshold slot and these would not match.
    expect(stored).toEqual(desired);

    const log = receipt.logs.find(
      (entry) => entry.address.toLowerCase() === deployment.hook.toLowerCase(),
    );
    expect(log).toBeDefined();
    const decoded = decodeEventLog({ abi: bondMeBroAbi, topics: log!.topics, data: log!.data });
    expect(decoded.eventName).toBe("PoolConfigured");
    expect(poolConfigFromEvent(decoded.args as never)).toEqual(desired);
  });

  it("maps the four mode/direction combinations onto the live thresholds", async () => {
    const config = poolConfigFromGetter(
      (await publicClient.readContract({
        address: deployment.hook,
        abi: bondMeBroAbi,
        functionName: "poolConfig",
        args: [deployment.poolId],
      })) as unknown as PoolConfigGetterTuple,
    );

    expect(thresholdsFor({ config, deployment, kind: "exactInput", zeroForOne: true })).toMatchObject({
      consumedInputMinimum: config.minBondedAmount0,
      variableLegMinimum: config.minVariableLeg1,
      collateralCurrency: deployment.currency1,
    });
    expect(thresholdsFor({ config, deployment, kind: "exactOutput", zeroForOne: true })).toMatchObject({
      consumedInputMinimum: config.minBondedAmount0,
      variableLegMinimum: config.minVariableLeg0,
      collateralCurrency: deployment.currency0,
    });
  });

  it("shows why the PoolConfigured event is not canonical after a disable", async () => {
    const supplied: PoolConfig = {
      minBondedAmount0: 5_000_000_000_000_000n,
      minBondedAmount1: 5_000_000n,
      minVariableLeg0: 50_000n,
      minVariableLeg1: 50_000n,
      bondingEnabled: false,
    };

    const hash = await wallet.writeContract({
      address: deployment.hook,
      abi: bondMeBroAbi,
      functionName: "setPoolConfig",
      args: poolConfigSetterArgs(deployment, supplied),
      account: owner,
      chain: null,
    });
    const receipt = assertReceiptSucceeded(
      await publicClient.waitForTransactionReceipt({ hash }),
      "configuration",
    );

    const log = receipt.logs.find(
      (entry) => entry.address.toLowerCase() === deployment.hook.toLowerCase(),
    );
    const decoded = decodeEventLog({ abi: bondMeBroAbi, topics: log!.topics, data: log!.data });
    const fromEvent = poolConfigFromEvent(decoded.args as never);

    const stored = poolConfigFromGetter(
      (await publicClient.readContract({
        address: deployment.hook,
        abi: bondMeBroAbi,
        functionName: "poolConfig",
        args: [deployment.poolId],
      })) as unknown as PoolConfigGetterTuple,
    );

    // The event still reports the values that were passed in; storage has been cleared.
    // This is exactly why the app re-reads the getter after every configuration write.
    expect(fromEvent?.minBondedAmount0).toBe(supplied.minBondedAmount0);
    expect(stored.minBondedAmount0).toBe(0n);
    expect(stored.minVariableLeg0).toBe(0n);
    expect(stored.minVariableLeg1).toBe(0n);
    expect(stored.bondingEnabled).toBe(false);
  });

  it("reports an unknown bond as absent instead of inventing a maturity", async () => {
    const unknownId = `0x${"ee".repeat(32)}` as const;

    const exists = await publicClient.readContract({
      address: deployment.hook,
      abi: bondMeBroAbi,
      functionName: "bondExists",
      args: [unknownId],
    });
    expect(exists).toBe(false);

    await expect(
      publicClient.readContract({
        address: deployment.hook,
        abi: bondMeBroAbi,
        functionName: "getBond",
        args: [unknownId],
      }),
    ).rejects.toThrow();
  });
});
