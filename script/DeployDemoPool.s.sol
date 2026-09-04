// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {BondMeBro} from "../src/BondMeBro.sol";
import {DemoToken} from "./DemoToken.sol";
import {DemoPoolParams} from "./DemoPoolParams.sol";

/// @title DeployDemoPool
/// @notice Stands up the BondMeBro hookathon demo pool on a live network, against an
/// ALREADY DEPLOYED hook.
///
/// @dev This script never deploys or modifies the hook. It reads the live hook, refuses to
/// continue unless it is the expected contract, and then builds a pool around it:
///
///   Phase 1  deploy two demo ERC-20s with DIFFERENT decimals
///   Phase 2  sort them into currency0/currency1 and derive the initial price
///   Phase 3  initialize the hooked pool
///   Phase 4  grant the PositionManager its allowances through Permit2
///   Phase 5  add broad-range liquidity
///   Phase 6  configure BMB-01 participation
///   Phase 7  read everything back and verify
///
/// Every parameter lives in DemoPoolParams, which the fork rehearsal imports too, so the
/// rehearsal cannot pass against different numbers from the ones broadcast here.
///
/// The token pair is deliberately 6-decimal against 18-decimal. Both BMB-01 minimums are
/// raw-unit quantities in two different currencies, and an 18-decimal assumption anywhere
/// in the chain shows up here as a millionfold error rather than a subtle one.
///
/// Run it as a simulation first — no `--broadcast`:
///
///   forge script script/DeployDemoPool.s.sol:DeployDemoPool \
///     --rpc-url https://sepolia.unichain.org --sender <HOOK_OWNER>
contract DeployDemoPool is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Everything the phases hand to one another. A struct rather than locals so the
    /// script stays well clear of stack limits.
    struct Ctx {
        address deployer;
        DemoToken usdc;
        DemoToken weth;
        bool usdcIsCurrency0;
        PoolKey key;
        PoolId poolId;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Max;
        uint256 amount1Max;
    }

    function run() external {
        Ctx memory c;
        c.deployer = msg.sender;

        _validateLiveHook(c.deployer);

        _phase1DeployTokens(c);
        _phase2SortAndPrice(c);

        vm.startBroadcast();
        _phase3InitializePool(c);
        _phase4Approve(c);
        _phase5AddLiquidity(c);
        _phase6Configure(c);
        vm.stopBroadcast();

        _phase7Verify(c);
    }

    // ---------------------------------------------------------------------------------
    // Pre-flight: the hook must be the contract we think it is.
    // ---------------------------------------------------------------------------------

    /// @dev Fails closed on every mismatch. A demo pool built around the wrong hook, or a
    /// hook whose owner is not the caller, would look like a working deployment and behave
    /// like a broken one.
    function _validateLiveHook(address deployer) internal view {
        console2.log("== hook validation ==");

        require(DemoPoolParams.HOOK.code.length > 0, "DeployDemoPool: no code at hook address");

        require(
            uint160(DemoPoolParams.HOOK) & 0x3FFF == DemoPoolParams.REQUIRED_HOOK_MASK,
            "DeployDemoPool: hook permission bits are not 0x10C4"
        );

        BondMeBro hook = BondMeBro(DemoPoolParams.HOOK);

        require(
            address(hook.poolManager()) == DemoPoolParams.POOL_MANAGER,
            "DeployDemoPool: hook points at a different PoolManager"
        );

        // setPoolConfig is owner-gated, so a deployer who is not the owner would complete
        // five phases and revert on the sixth, leaving a pool with no configuration.
        require(hook.owner() == deployer, "DeployDemoPool: sender is not the hook owner");

        require(DemoPoolParams.POOL_MANAGER.code.length > 0, "DeployDemoPool: no code at PoolManager");
        require(DemoPoolParams.POSITION_MANAGER.code.length > 0, "DeployDemoPool: no code at PositionManager");
        require(DemoPoolParams.PERMIT2.code.length > 0, "DeployDemoPool: no code at Permit2");

        console2.log("  chainid         ", block.chainid);
        console2.log("  hook            ", DemoPoolParams.HOOK);
        console2.log("  hook mask       ", uint256(uint160(DemoPoolParams.HOOK) & 0x3FFF));
        console2.log("  hook owner      ", hook.owner());
        console2.log("  poolManager     ", address(hook.poolManager()));
        console2.log("  BPS             ", hook.BPS());
        console2.log("  MAX_BOND_BPS    ", uint256(hook.MAX_BOND_BPS()));
        console2.log("  OBSERVATION     ", uint256(hook.OBSERVATION_BLOCKS()));
        console2.log("  deployer        ", deployer);
    }

    // ---------------------------------------------------------------------------------
    // Phase 1 — deploy the demo tokens
    // ---------------------------------------------------------------------------------

    function _phase1DeployTokens(Ctx memory c) internal {
        console2.log("== phase 1: deploy demo tokens ==");

        vm.startBroadcast();
        c.usdc = new DemoToken(
            "BondMeBro Demo USDC", "bUSDC", DemoPoolParams.USDC_DECIMALS, DemoPoolParams.USDC_SUPPLY, c.deployer
        );
        c.weth = new DemoToken(
            "BondMeBro Demo WETH", "bWETH", DemoPoolParams.WETH_DECIMALS, DemoPoolParams.WETH_SUPPLY, c.deployer
        );
        vm.stopBroadcast();

        console2.log("  bUSDC           ", address(c.usdc));
        console2.log("  bUSDC decimals  ", uint256(c.usdc.decimals()));
        console2.log("  bUSDC supply    ", c.usdc.totalSupply());
        console2.log("  bWETH           ", address(c.weth));
        console2.log("  bWETH decimals  ", uint256(c.weth.decimals()));
        console2.log("  bWETH supply    ", c.weth.totalSupply());
    }

    // ---------------------------------------------------------------------------------
    // Phase 2 — currency ordering and initial price
    // ---------------------------------------------------------------------------------

    /// @dev A PoolKey requires currency0 < currency1 as addresses, and the token that wins
    /// that comparison is decided by CREATE, not by us. Both orderings are handled, and the
    /// resulting price is proved against the intended human price before anything is signed.
    function _phase2SortAndPrice(Ctx memory c) internal pure {
        console2.log("== phase 2: ordering and price ==");

        c.usdcIsCurrency0 = address(c.usdc) < address(c.weth);

        (Currency currency0, Currency currency1) = c.usdcIsCurrency0
            ? (Currency.wrap(address(c.usdc)), Currency.wrap(address(c.weth)))
            : (Currency.wrap(address(c.weth)), Currency.wrap(address(c.usdc)));

        c.key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: DemoPoolParams.FEE,
            tickSpacing: DemoPoolParams.TICK_SPACING,
            hooks: IHooks(DemoPoolParams.HOOK)
        });
        c.poolId = c.key.toId();

        c.sqrtPriceX96 = DemoPoolParams.sqrtPriceX96For(c.usdcIsCurrency0);

        // PROOF, not assertion by comment: decode the price back out of sqrtPriceX96 and
        // require it to be the intended figure. The recovered value is carried in millionths
        // of a bUSDC so the check has real resolution and the log is unambiguous — a whole-
        // number readback would print 2499 purely from truncation and look like a fault.
        //
        // A tenth of a percent of slack absorbs the sqrt truncation. Any genuine ordering or
        // decimals mistake is wrong by twelve orders of magnitude, not by a tenth of a percent.
        uint256 recoveredX6 = DemoPoolParams.impliedUsdcPerWethX6(c.sqrtPriceX96, c.usdcIsCurrency0);
        uint256 targetX6 = DemoPoolParams.USDC_PER_WETH * 1e6;
        require(
            recoveredX6 >= targetX6 - targetX6 / 1000 && recoveredX6 <= targetX6 + targetX6 / 1000,
            "DeployDemoPool: sqrtPriceX96 does not encode the intended human price"
        );

        c.tickLower = DemoPoolParams.alignedMinTick(DemoPoolParams.TICK_SPACING);
        c.tickUpper = DemoPoolParams.alignedMaxTick(DemoPoolParams.TICK_SPACING);

        (c.amount0Desired, c.amount1Desired) = c.usdcIsCurrency0
            ? (DemoPoolParams.USDC_LIQUIDITY, DemoPoolParams.WETH_LIQUIDITY)
            : (DemoPoolParams.WETH_LIQUIDITY, DemoPoolParams.USDC_LIQUIDITY);

        c.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            c.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(c.tickLower),
            TickMath.getSqrtPriceAtTick(c.tickUpper),
            c.amount0Desired,
            c.amount1Desired
        );
        require(c.liquidity > 0, "DeployDemoPool: computed zero liquidity");

        // One percent of headroom over the desired amounts absorbs the rounding-up the
        // PositionManager applies when it converts liquidity back into token amounts. The
        // deployer holds ten times the deposit, so the headroom is always available.
        c.amount0Max = c.amount0Desired + c.amount0Desired / 100;
        c.amount1Max = c.amount1Desired + c.amount1Desired / 100;

        console2.log("  usdcIsCurrency0 ", c.usdcIsCurrency0);
        console2.log("  currency0       ", Currency.unwrap(currency0));
        console2.log("  currency1       ", Currency.unwrap(currency1));
        console2.log("  fee             ", uint256(DemoPoolParams.FEE));
        console2.log("  tickSpacing     ", int256(DemoPoolParams.TICK_SPACING));
        console2.log("  sqrtPriceX96    ", uint256(c.sqrtPriceX96));
        console2.log("  initial tick    ", int256(TickMath.getTickAtSqrtPrice(c.sqrtPriceX96)));
        console2.log("  bUSDC per bWETH ", recoveredX6);
        console2.log("    (millionths of a bUSDC; 2500000000 == 2500.000000)");
        console2.log("  tickLower       ", int256(c.tickLower));
        console2.log("  tickUpper       ", int256(c.tickUpper));
        console2.log("  liquidity       ", uint256(c.liquidity));
        console2.log("  poolId          ", uint256(PoolId.unwrap(c.poolId)));
    }

    // ---------------------------------------------------------------------------------
    // Phase 3 — initialize the hooked pool
    // ---------------------------------------------------------------------------------

    /// @dev Calls PoolManager directly rather than PositionManager.initializePool, which
    /// wraps the call in a try/catch and returns type(int24).max on failure. A deployment
    /// script must not be able to sail past a failed initialization — in particular a
    /// failure inside the hook's own afterInitialize.
    function _phase3InitializePool(Ctx memory c) internal {
        console2.log("== phase 3: initialize pool ==");

        int24 tick = IPoolManager(DemoPoolParams.POOL_MANAGER).initialize(c.key, c.sqrtPriceX96);

        console2.log("  initialized tick", int256(tick));
    }

    // ---------------------------------------------------------------------------------
    // Phase 4 — allowances
    // ---------------------------------------------------------------------------------

    /// @dev The PositionManager never pulls tokens directly: `_pay` calls
    /// `permit2.transferFrom(payer, poolManager, amount, token)`. That needs two grants per
    /// token — the ERC-20 allowance to Permit2, and Permit2's own allowance to the
    /// PositionManager. Both are bounded to this deposit and expire in an hour.
    function _phase4Approve(Ctx memory c) internal {
        console2.log("== phase 4: approvals ==");

        uint48 expiration = uint48(block.timestamp + 1 hours);

        address token0 = Currency.unwrap(c.key.currency0);
        address token1 = Currency.unwrap(c.key.currency1);

        DemoToken(token0).approve(DemoPoolParams.PERMIT2, c.amount0Max);
        DemoToken(token1).approve(DemoPoolParams.PERMIT2, c.amount1Max);

        IAllowanceTransfer(DemoPoolParams.PERMIT2)
            .approve(token0, DemoPoolParams.POSITION_MANAGER, uint160(c.amount0Max), expiration);
        IAllowanceTransfer(DemoPoolParams.PERMIT2)
            .approve(token1, DemoPoolParams.POSITION_MANAGER, uint160(c.amount1Max), expiration);

        console2.log("  permit2 <- token0 amount", c.amount0Max);
        console2.log("  permit2 <- token1 amount", c.amount1Max);
        console2.log("  posm spender expiry     ", uint256(expiration));
    }

    // ---------------------------------------------------------------------------------
    // Phase 5 — liquidity
    // ---------------------------------------------------------------------------------

    /// @dev MINT_POSITION then SETTLE_PAIR, the standard pinned-periphery pair: mint records
    /// the position and opens the two token debts, settle pays them. Parameter order is taken
    /// from CalldataDecoder.decodeMintParams, not from memory.
    function _phase5AddLiquidity(Ctx memory c) internal {
        console2.log("== phase 5: add liquidity ==");

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            c.key,
            c.tickLower,
            c.tickUpper,
            uint256(c.liquidity),
            uint128(c.amount0Max),
            uint128(c.amount1Max),
            c.deployer,
            bytes("")
        );
        params[1] = abi.encode(c.key.currency0, c.key.currency1);

        IPositionManager(DemoPoolParams.POSITION_MANAGER)
            .modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);

        console2.log("  minted liquidity", uint256(c.liquidity));
        console2.log("  position owner  ", c.deployer);
    }

    // ---------------------------------------------------------------------------------
    // Phase 6 — BMB-01 configuration
    // ---------------------------------------------------------------------------------

    /// @dev setPoolConfig's argument order puts `bondingEnabled` LAST, while the public
    /// getter returns it THIRD. The two are not interchangeable and are written out here in
    /// the setter's order deliberately.
    function _phase6Configure(Ctx memory c) internal {
        console2.log("== phase 6: BMB-01 configuration ==");

        (uint128 minInput0, uint96 minInput1, uint128 minLeg0, uint128 minLeg1) =
            DemoPoolParams.thresholds(c.usdcIsCurrency0);

        BondMeBro(DemoPoolParams.HOOK).setPoolConfig(c.key, minInput0, minInput1, minLeg0, minLeg1, true);

        console2.log("  minBondedAmount0", uint256(minInput0));
        console2.log("  minBondedAmount1", uint256(minInput1));
        console2.log("  minVariableLeg0 ", uint256(minLeg0));
        console2.log("  minVariableLeg1 ", uint256(minLeg1));
        console2.log("  bondingEnabled   true");
    }

    // ---------------------------------------------------------------------------------
    // Phase 7 — read back and verify
    // ---------------------------------------------------------------------------------

    /// @dev Everything here is a read of committed state. Split into small helpers so each
    /// one stays well inside the stack limit.
    function _phase7Verify(Ctx memory c) internal view {
        console2.log("== phase 7: verification ==");

        _verifyPoolState(c);
        _verifyPoolConfig(c);
        _logBalances(c);
        _logManifest(c);
    }

    /// @dev The pool index is the proof that the hook's afterInitialize actually ran: it is
    /// assigned there and nowhere else.
    function _verifyPoolState(Ctx memory c) internal view {
        uint32 poolIndex = BondMeBro(DemoPoolParams.HOOK).poolIndexOf(c.poolId);
        require(poolIndex != 0, "DeployDemoPool: hook did not register the pool in afterInitialize");

        (uint160 sqrtPriceX96, int24 tick,,) = IPoolManager(DemoPoolParams.POOL_MANAGER).getSlot0(c.poolId);
        require(sqrtPriceX96 == c.sqrtPriceX96, "DeployDemoPool: pool price is not the initialized price");

        uint128 poolLiquidity = IPoolManager(DemoPoolParams.POOL_MANAGER).getLiquidity(c.poolId);
        require(poolLiquidity >= c.liquidity, "DeployDemoPool: pool liquidity is below the minted amount");

        console2.log("  pool index      ", uint256(poolIndex));
        console2.log("  slot0 sqrtPrice ", uint256(sqrtPriceX96));
        console2.log("  slot0 tick      ", int256(tick));
        console2.log("  pool liquidity  ", uint256(poolLiquidity));
    }

    /// @dev Reads the config back through the GETTER, whose field order differs from the
    /// setter's, and checks every field against what was written.
    function _verifyPoolConfig(Ctx memory c) internal view {
        BondMeBro hook = BondMeBro(DemoPoolParams.HOOK);

        (
            uint128 minBondedAmount0,
            uint96 minBondedAmount1,
            bool bondingEnabled,
            uint128 minVariableLeg0,
            uint128 minVariableLeg1
        ) = hook.poolConfig(c.poolId);

        (uint128 wantInput0, uint96 wantInput1, uint128 wantLeg0, uint128 wantLeg1) =
            DemoPoolParams.thresholds(c.usdcIsCurrency0);

        require(bondingEnabled, "DeployDemoPool: bonding not enabled");
        require(minBondedAmount0 == wantInput0, "DeployDemoPool: minBondedAmount0 mismatch");
        require(minBondedAmount1 == wantInput1, "DeployDemoPool: minBondedAmount1 mismatch");
        require(minVariableLeg0 == wantLeg0, "DeployDemoPool: minVariableLeg0 mismatch");
        require(minVariableLeg1 == wantLeg1, "DeployDemoPool: minVariableLeg1 mismatch");

        require(minVariableLeg0 >= hook.BPS(), "DeployDemoPool: minVariableLeg0 below the BPS floor");
        require(minVariableLeg1 >= hook.BPS(), "DeployDemoPool: minVariableLeg1 below the BPS floor");

        console2.log("  cfg minInput0   ", uint256(minBondedAmount0));
        console2.log("  cfg minInput1   ", uint256(minBondedAmount1));
        console2.log("  cfg minLeg0     ", uint256(minVariableLeg0));
        console2.log("  cfg minLeg1     ", uint256(minVariableLeg1));
        console2.log("  cfg enabled     ", bondingEnabled);
    }

    function _logBalances(Ctx memory c) internal view {
        console2.log("  deployer bUSDC  ", c.usdc.balanceOf(c.deployer));
        console2.log("  deployer bWETH  ", c.weth.balanceOf(c.deployer));
    }

    /// @dev The exact values the remediated frontend needs. Its manifest fails closed, so
    /// printing them here avoids a hand-transcription mistake.
    function _logManifest(Ctx memory c) internal view {
        console2.log("== frontend manifest ==");
        console2.log("  NEXT_PUBLIC_CHAIN_ID        ", block.chainid);
        console2.log("  NEXT_PUBLIC_HOOK_ADDRESS    ", DemoPoolParams.HOOK);
        console2.log("  NEXT_PUBLIC_POOL_MANAGER    ", DemoPoolParams.POOL_MANAGER);
        console2.log("  NEXT_PUBLIC_UNIVERSAL_ROUTER", DemoPoolParams.UNIVERSAL_ROUTER);
        console2.log("  NEXT_PUBLIC_QUOTER          ", DemoPoolParams.QUOTER);
        console2.log("  NEXT_PUBLIC_PERMIT2         ", DemoPoolParams.PERMIT2);
        console2.log("  NEXT_PUBLIC_CURRENCY0       ", Currency.unwrap(c.key.currency0));
        console2.log("  NEXT_PUBLIC_CURRENCY1       ", Currency.unwrap(c.key.currency1));
        console2.log("  NEXT_PUBLIC_POOL_FEE        ", uint256(DemoPoolParams.FEE));
        console2.log("  NEXT_PUBLIC_TICK_SPACING    ", int256(DemoPoolParams.TICK_SPACING));
        console2.log("  NEXT_PUBLIC_POOL_ID         ", uint256(PoolId.unwrap(c.poolId)));
    }
}
