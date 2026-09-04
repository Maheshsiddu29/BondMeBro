// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test, Vm, console2} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {BondMeBro} from "../../src/BondMeBro.sol";
import {DemoToken} from "../../script/DemoToken.sol";
import {DemoPoolParams} from "../../script/DemoPoolParams.sol";

/// @dev The Universal Router is not vendored in this repository's dependency tree, so its
/// one entry point is declared here exactly as the frontend declares it.
interface IUniversalRouterMinimal {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev THE DEPLOYED ROUTER'S SWAP PARAMETERS, WHICH ARE NOT THE PINNED ONES.
///
/// `IV4Router.ExactInputSingleParams` in the v4-periphery pinned here carries a
/// `minHopPriceX36` field between `amountOutMinimum` and `hookData`. The Universal Router
/// deployed at 0x7f9b…a37b on Unichain Sepolia was built against an EARLIER v4-periphery
/// that has no such field, and its calldata decoder is strict: an extra word shifts the
/// `hookData` offset and the call reverts inside `unlockCallback` before any swap happens.
///
/// This was established empirically on the fork, not assumed — encoding the pinned struct
/// reverts, encoding these structs succeeds. The frontend's router tuples must match THESE
/// shapes, not the pinned interface's.
struct RouterExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

struct RouterExactOutputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountOut;
    uint128 amountInMaximum;
    bytes hookData;
}

/// @title DemoPoolForkRehearsal
/// @notice Proves the whole demo lifecycle against a Unichain Sepolia fork, using the LIVE
/// deployed hook and the same router/periphery path the frontend will use.
///
/// @dev This is a rehearsal, not a unit test. It builds the pool exactly as
/// `script/DeployDemoPool.s.sol` would — importing the same `DemoPoolParams`, so it cannot
/// pass against different numbers from the ones that would be broadcast — and then swaps
/// through the deployed Universal Router with version 2 hookData.
///
/// It is skipped unless a fork endpoint is supplied, so the offline suite is unaffected:
///
///   UNICHAIN_SEPOLIA_RPC_URL=https://sepolia.unichain.org \
///     forge test --match-path 'test/fork/*' -vv
contract DemoPoolForkRehearsal is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Universal Router command byte for a V4 swap plan.
    bytes internal constant V4_SWAP = hex"10";

    /// @dev Zero means "the whole debt" for SETTLE and "the whole credit" for TAKE.
    uint256 internal constant OPEN_DELTA = 0;

    /// @dev Pinned fork height, comfortably after the hook's deployment at 61,614,792.
    /// Pinning rather than forking at the tip keeps the rehearsal deterministic and lets
    /// Foundry reuse its RPC cache; forking at "latest" once produced a transient empty
    /// account read that was then cached for that height. Override with
    /// UNICHAIN_SEPOLIA_FORK_BLOCK if a later height is needed.
    uint256 internal constant FORK_BLOCK = 61_618_292;

    /// @dev Lifecycle values from BondMeBro.BondState.
    uint8 internal constant STATE_FINALIZED = 2;
    uint8 internal constant STATE_SETTLED = 3;

    BondMeBro internal hook = BondMeBro(DemoPoolParams.HOOK);
    IPoolManager internal poolManager = IPoolManager(DemoPoolParams.POOL_MANAGER);

    address internal owner = 0xA5B709025224bA08B8eFfF1b0D1d28E970A34Cf3;
    address internal trader = makeAddr("bondmebro-demo-trader");
    address internal settler = makeAddr("bondmebro-unrelated-settler");

    DemoToken internal usdc;
    DemoToken internal weth;
    bool internal usdcIsCurrency0;

    PoolKey internal key;
    PoolId internal poolId;
    uint160 internal initialSqrtPriceX96;

    bool internal forked;

    // ---------------------------------------------------------------------------------
    // Setup: the DeployDemoPool sequence, replayed on a fork
    // ---------------------------------------------------------------------------------

    function setUp() public {
        string memory rpc = vm.envOr("UNICHAIN_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envOr("UNICHAIN_SEPOLIA_FORK_BLOCK", FORK_BLOCK));
        forked = true;

        _assertLiveHook();
        _deployTokens();
        _sortAndInitialize();
        _addLiquidity();
        _configure();
        _fundTrader();
    }

    /// @dev The same fail-closed checks the deployment script performs.
    function _assertLiveHook() internal view {
        assertGt(
            DemoPoolParams.HOOK.code.length,
            0,
            "no code at the hook on this fork: check the fork height and clear the RPC cache"
        );
        assertEq(uint160(DemoPoolParams.HOOK) & 0x3FFF, DemoPoolParams.REQUIRED_HOOK_MASK, "hook mask");
        assertEq(address(hook.poolManager()), DemoPoolParams.POOL_MANAGER, "hook poolManager");
        assertEq(hook.owner(), owner, "hook owner");
        assertEq(hook.OBSERVATION_BLOCKS(), 10, "observation horizon");
    }

    function _deployTokens() internal {
        vm.startPrank(owner);
        usdc = new DemoToken(
            "BondMeBro Demo USDC", "bUSDC", DemoPoolParams.USDC_DECIMALS, DemoPoolParams.USDC_SUPPLY, owner
        );
        weth = new DemoToken(
            "BondMeBro Demo WETH", "bWETH", DemoPoolParams.WETH_DECIMALS, DemoPoolParams.WETH_SUPPLY, owner
        );
        vm.stopPrank();
    }

    function _sortAndInitialize() internal {
        usdcIsCurrency0 = address(usdc) < address(weth);

        (Currency currency0, Currency currency1) = usdcIsCurrency0
            ? (Currency.wrap(address(usdc)), Currency.wrap(address(weth)))
            : (Currency.wrap(address(weth)), Currency.wrap(address(usdc)));

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: DemoPoolParams.FEE,
            tickSpacing: DemoPoolParams.TICK_SPACING,
            hooks: IHooks(DemoPoolParams.HOOK)
        });
        poolId = key.toId();

        initialSqrtPriceX96 = DemoPoolParams.sqrtPriceX96For(usdcIsCurrency0);

        vm.prank(owner);
        poolManager.initialize(key, initialSqrtPriceX96);

        // afterInitialize is the only place a pool index is assigned.
        assertGt(hook.poolIndexOf(poolId), 0, "hook did not register the pool");
    }

    function _addLiquidity() internal {
        int24 tickLower = DemoPoolParams.alignedMinTick(DemoPoolParams.TICK_SPACING);
        int24 tickUpper = DemoPoolParams.alignedMaxTick(DemoPoolParams.TICK_SPACING);

        (uint256 amount0Desired, uint256 amount1Desired) = usdcIsCurrency0
            ? (DemoPoolParams.USDC_LIQUIDITY, DemoPoolParams.WETH_LIQUIDITY)
            : (DemoPoolParams.WETH_LIQUIDITY, DemoPoolParams.USDC_LIQUIDITY);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            initialSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );

        uint256 amount0Max = amount0Desired + amount0Desired / 100;
        uint256 amount1Max = amount1Desired + amount1Desired / 100;

        vm.startPrank(owner);
        _approveThroughPermit2(Currency.unwrap(key.currency0), DemoPoolParams.POSITION_MANAGER, amount0Max);
        _approveThroughPermit2(Currency.unwrap(key.currency1), DemoPoolParams.POSITION_MANAGER, amount1Max);

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, tickLower, tickUpper, uint256(liquidity), uint128(amount0Max), uint128(amount1Max), owner, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);

        IPositionManager(DemoPoolParams.POSITION_MANAGER)
            .modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
        vm.stopPrank();

        assertGe(poolManager.getLiquidity(poolId), liquidity, "pool liquidity");
    }

    function _configure() internal {
        (uint128 minInput0, uint96 minInput1, uint128 minLeg0, uint128 minLeg1) =
            DemoPoolParams.thresholds(usdcIsCurrency0);

        vm.prank(owner);
        hook.setPoolConfig(key, minInput0, minInput1, minLeg0, minLeg1, true);

        (,, bool bondingEnabled,,) = hook.poolConfig(poolId);
        assertTrue(bondingEnabled, "bonding not enabled");
    }

    /// @dev The trader is a separate account from the pool owner so the refund destination
    /// is unambiguous, and the settler is a third account with no stake in either.
    function _fundTrader() internal {
        vm.startPrank(owner);
        usdc.transfer(trader, 500_000 * 10 ** DemoPoolParams.USDC_DECIMALS);
        weth.transfer(trader, 200 * 10 ** DemoPoolParams.WETH_DECIMALS);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------

    function _approveThroughPermit2(address token, address spender, uint256 amount) internal {
        DemoToken(token).approve(DemoPoolParams.PERMIT2, amount);
        IAllowanceTransfer(DemoPoolParams.PERMIT2)
            .approve(token, spender, uint160(amount), uint48(block.timestamp + 1 hours));
    }

    /// @dev hookData version 2: one version byte, twenty address bytes, sixteen amount
    /// bytes. Exactly 37 packed bytes, matching HookDataCodec.
    function _hookDataV2(address refundRecipient, uint128 maxBondAmount) internal pure returns (bytes memory data) {
        data = abi.encodePacked(uint8(2), refundRecipient, maxBondAmount);
        require(data.length == 37, "hookData must be 37 bytes");
    }

    function _tokenOf(bool isCurrency0) internal view returns (DemoToken) {
        return DemoToken(Currency.unwrap(isCurrency0 ? key.currency0 : key.currency1));
    }

    struct Opened {
        bytes32 bondId;
        address refundRecipient;
        uint128 variableLegAmount;
        uint32 maturityBlock;
        bool found;
    }

    /// @dev Pulls this transaction's BondOpened out of the recorded logs. The topic hash
    /// comes from the contract's own event definition, never a hand-written string.
    function _findBondOpened(Vm.Log[] memory logs) internal view returns (Opened memory o) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != DemoPoolParams.HOOK) continue;
            if (logs[i].topics.length != 4) continue;
            if (logs[i].topics[0] != BondMeBro.BondOpened.selector) continue;
            if (logs[i].topics[2] != PoolId.unwrap(poolId)) continue;

            o.bondId = logs[i].topics[1];
            o.refundRecipient = address(uint160(uint256(logs[i].topics[3])));
            (o.variableLegAmount, o.maturityBlock) = abi.decode(logs[i].data, (uint128, uint32));
            o.found = true;
            return o;
        }
    }

    struct Taken {
        address currency;
        uint256 bond;
        uint256 variableLegAmount;
        bool found;
    }

    function _findBondTaken(Vm.Log[] memory logs) internal pure returns (Taken memory t) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != DemoPoolParams.HOOK) continue;
            if (logs[i].topics.length != 4) continue;
            if (logs[i].topics[0] != BondMeBro.BondTaken.selector) continue;

            t.currency = address(uint160(uint256(logs[i].topics[3])));
            (t.bond, t.variableLegAmount) = abi.decode(logs[i].data, (uint256, uint256));
            t.found = true;
            return t;
        }
    }

    struct Settled {
        address currency;
        uint128 collateral;
        uint128 refund;
        uint128 slash;
        uint16 slashBps;
        bool found;
    }

    function _findBondSettled(Vm.Log[] memory logs, bytes32 bondId) internal pure returns (Settled memory s) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != DemoPoolParams.HOOK) continue;
            if (logs[i].topics.length != 4) continue;
            if (logs[i].topics[0] != BondMeBro.BondSettled.selector) continue;
            if (logs[i].topics[1] != bondId) continue;

            (s.currency, s.collateral, s.refund, s.slash, s.slashBps) =
                abi.decode(logs[i].data, (address, uint128, uint128, uint128, uint16));
            s.found = true;
            return s;
        }
    }

    /// @dev The frontend's exact-input plan: SWAP_EXACT_IN_SINGLE, SETTLE, TAKE.
    function _swapExactInput(bool zeroForOne, uint128 amountIn, uint128 amountOutMinimum, bytes memory hookData)
        internal
    {
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            RouterExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                hookData: hookData
            })
        );
        params[1] = abi.encode(inputCurrency, OPEN_DELTA, true);
        params[2] = abi.encode(outputCurrency, trader, OPEN_DELTA);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        IUniversalRouterMinimal(DemoPoolParams.UNIVERSAL_ROUTER).execute(V4_SWAP, inputs, block.timestamp + 1 hours);
    }

    /// @dev The frontend's exact-output plan: SWAP_EXACT_OUT_SINGLE, SETTLE, TAKE.
    function _swapExactOutput(bool zeroForOne, uint128 amountOut, uint128 amountInMaximum, bytes memory hookData)
        internal
    {
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            RouterExactOutputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountOut: amountOut,
                amountInMaximum: amountInMaximum,
                hookData: hookData
            })
        );
        params[1] = abi.encode(inputCurrency, OPEN_DELTA, true);
        params[2] = abi.encode(outputCurrency, trader, OPEN_DELTA);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        IUniversalRouterMinimal(DemoPoolParams.UNIVERSAL_ROUTER).execute(V4_SWAP, inputs, block.timestamp + 1 hours);
    }

    // ---------------------------------------------------------------------------------
    // Encoding shape: the same invariant the frontend pins
    // ---------------------------------------------------------------------------------

    /// @dev Reads the nth 32-byte word of an ABI blob.
    function _wordAt(bytes memory encoded, uint256 index) internal pure returns (uint256 word) {
        require(encoded.length >= (index + 1) * 32, "word out of range");
        assembly {
            word := mload(add(add(encoded, 0x20), mul(index, 0x20)))
        }
    }

    /// @dev Ties this rehearsal's Solidity encoding to the frontend's TypeScript encoding.
    ///
    /// With the deployed router's five-slot head — tuple offset, five poolKey words,
    /// zeroForOne, and the two amounts — the hookData offset lands in word 9 and reads 0x120.
    /// The pinned v4-periphery struct adds `minHopPriceX36`, pushing it to 0x140, which is the
    /// displacement that makes the live router revert.
    ///
    /// `frontend/src/lib/__tests__/routerTuple.test.ts` asserts exactly 0x120 on the tuples the
    /// frontend encodes, against golden vectors produced by Solidity's own abi.encode. Both
    /// sides therefore agree on one checkable number.
    function test_routerTupleShapeMatchesFrontend() public view {
        bytes memory hookData = _hookDataV2(trader, type(uint128).max);

        bytes memory ei = abi.encode(
            RouterExactInputSingleParams({
                poolKey: key,
                zeroForOne: usdcIsCurrency0,
                amountIn: 1_000_000,
                amountOutMinimum: 900_000,
                hookData: hookData
            })
        );
        assertEq(_wordAt(ei, 9), 0x120, "exact-input hookData offset must be 0x120");
        assertEq(ei.length, 416, "exact-input encoding must be 416 bytes with 37-byte hookData");

        bytes memory eo = abi.encode(
            RouterExactOutputSingleParams({
                poolKey: key,
                zeroForOne: usdcIsCurrency0,
                amountOut: 500_000,
                amountInMaximum: 1_000_000,
                hookData: hookData
            })
        );
        assertEq(_wordAt(eo, 9), 0x120, "exact-output hookData offset must be 0x120");
        assertEq(eo.length, 416, "exact-output encoding must be 416 bytes with 37-byte hookData");
    }

    // ---------------------------------------------------------------------------------
    // 5. Bonded EXACT-INPUT swap, bUSDC -> bWETH
    // ---------------------------------------------------------------------------------

    function test_exactInput_bondsAndWithholdsFromOutput() public {
        // bUSDC is the input, so zeroForOne is true only when bUSDC sorted first.
        bool zeroForOne = usdcIsCurrency0;

        // Well above the 100 bUSDC input minimum, and large enough to move the tick.
        uint128 amountIn = uint128(10_000 * 10 ** DemoPoolParams.USDC_DECIMALS);

        // Exact input carries the unbounded ceiling; protection is amountOutMinimum.
        bytes memory hookData = _hookDataV2(trader, type(uint128).max);

        uint256 traderUsdcBefore = usdc.balanceOf(trader);
        uint256 traderWethBefore = weth.balanceOf(trader);
        uint256 hookWethBefore = weth.balanceOf(DemoPoolParams.HOOK);
        uint256 openBlock = block.number;

        vm.startPrank(trader);
        _approveThroughPermit2(address(usdc), DemoPoolParams.UNIVERSAL_ROUTER, amountIn);
        vm.recordLogs();
        _swapExactInput(zeroForOne, amountIn, 0, hookData);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        Opened memory opened = _findBondOpened(logs);
        Taken memory taken = _findBondTaken(logs);

        assertTrue(opened.found, "BondOpened not emitted");
        assertTrue(taken.found, "BondTaken not emitted");

        // THE SPECIFIED INPUT IS NOT CARVED UP. The trader spends exactly what was asked.
        assertEq(traderUsdcBefore - usdc.balanceOf(trader), amountIn, "input was carved out");

        // The collateral currency for an exact-input swap is the OUTPUT token.
        assertEq(taken.currency, address(weth), "collateral currency should be the output");

        // The variable leg is the realized output; the trader receives it MINUS collateral.
        uint256 traderReceived = weth.balanceOf(trader) - traderWethBefore;
        assertEq(taken.variableLegAmount, opened.variableLegAmount, "variable leg disagreement");
        assertEq(traderReceived, opened.variableLegAmount - taken.bond, "output not reduced by collateral");
        assertGt(taken.bond, 0, "no collateral withheld");

        // Contract-held collateral accounting: the hook's balance rises by exactly the bond.
        assertEq(weth.balanceOf(DemoPoolParams.HOOK) - hookWethBefore, taken.bond, "hook custody");
        assertEq(hook.collateralAmountOf(opened.bondId), taken.bond, "collateralAmountOf");

        BondMeBro.Bond memory bond = hook.getBond(opened.bondId);
        assertEq(bond.refundRecipient, trader, "refundRecipient must come from hookData");
        assertEq(opened.refundRecipient, trader, "event recipient");
        assertEq(bond.variableLegAmount, opened.variableLegAmount, "stored variable leg");
        assertGt(bond.collateralBps, 0, "collateralBps must be positive");
        assertEq(uint256(bond.openBlock), openBlock, "openBlock");
        assertEq(uint256(bond.maturityBlock), openBlock + 10, "maturityBlock must be open + 10");
        assertEq(uint256(bond.maturityBlock), uint256(opened.maturityBlock), "event maturity");
        assertEq(uint8(bond.state), STATE_FINALIZED, "state");
        assertEq(bond.collateralIsCurrency0, !zeroForOne, "collateral side");

        // The stored rate reproduces the collateral exactly.
        assertEq(taken.bond, (uint256(bond.variableLegAmount) * bond.collateralBps) / hook.BPS(), "rate reconciliation");

        console2.log("EI  variableLeg (bWETH raw)", opened.variableLegAmount);
        console2.log("EI  collateral  (bWETH raw)", taken.bond);
        console2.log("EI  collateralBps          ", uint256(bond.collateralBps));
        console2.log("EI  open / maturity        ", uint256(bond.openBlock), uint256(bond.maturityBlock));
    }

    // ---------------------------------------------------------------------------------
    // 6. Bonded EXACT-OUTPUT swap in the opposite direction, bWETH -> bUSDC
    // ---------------------------------------------------------------------------------

    /// @dev The exact-output limits the frontend derives, kept in a struct so the test body
    /// stays inside the stack limit.
    struct EOPlan {
        uint256 quotedTotalInput;
        uint128 amountInMaximum;
        uint128 maxBondAmount;
    }

    /// @dev Mirrors the frontend exactly. The quoter's exact-output result is the TOTAL
    /// input, collateral already included, so the user's slippage is applied ONCE and no
    /// second collateral allowance is layered on top. Both expressions read the hook's own
    /// constants rather than a hardcoded divisor.
    function _planExactOutput(bool zeroForOne, uint128 amountOut, uint256 toleranceBps)
        internal
        returns (EOPlan memory plan)
    {
        (plan.quotedTotalInput,) = IV4Quoter(DemoPoolParams.QUOTER)
            .quoteExactOutputSingle(
                IV4Quoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                exactAmount: amountOut,
                hookData: _hookDataV2(trader, type(uint128).max)
            })
            );

        uint256 bps = hook.BPS();
        uint256 cap = hook.MAX_BOND_BPS();

        plan.amountInMaximum = uint128((plan.quotedTotalInput * (bps + toleranceBps) + bps - 1) / bps);
        plan.maxBondAmount = uint128((uint256(plan.amountInMaximum) * cap) / (bps + cap));
    }

    struct Balances {
        uint256 traderIn;
        uint256 traderOut;
        uint256 hookCollateral;
    }

    function test_exactOutput_bondsAndTakesFromInput() public {
        // bWETH is now the input, so the direction flips relative to the exact-input case.
        bool zeroForOne = !usdcIsCurrency0;
        uint128 amountOut = uint128(10_000 * 10 ** DemoPoolParams.USDC_DECIMALS);

        EOPlan memory plan = _planExactOutput(zeroForOne, amountOut, 100);
        assertGt(plan.maxBondAmount, 0, "derived ceiling rounded to zero");

        Balances memory before =
            Balances(weth.balanceOf(trader), usdc.balanceOf(trader), weth.balanceOf(DemoPoolParams.HOOK));
        uint256 openBlock = block.number;

        vm.startPrank(trader);
        _approveThroughPermit2(address(weth), DemoPoolParams.UNIVERSAL_ROUTER, plan.amountInMaximum);
        vm.recordLogs();
        _swapExactOutput(zeroForOne, amountOut, plan.amountInMaximum, _hookDataV2(trader, plan.maxBondAmount));
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        Opened memory opened = _findBondOpened(logs);
        Taken memory taken = _findBondTaken(logs);

        assertTrue(opened.found, "BondOpened not emitted");
        assertTrue(taken.found, "BondTaken not emitted");

        // THE REQUESTED OUTPUT IS DELIVERED EXACTLY.
        assertEq(usdc.balanceOf(trader) - before.traderOut, amountOut, "exact output not delivered");

        // Collateral is taken from the INPUT side for exact output.
        assertEq(taken.currency, address(weth), "collateral currency should be the input");

        // Total input = pool input (the variable leg) + collateral, within the authorised cap.
        uint256 totalSpent = before.traderIn - weth.balanceOf(trader);
        assertEq(totalSpent, opened.variableLegAmount + taken.bond, "total input must include collateral");
        assertLe(totalSpent, plan.amountInMaximum, "total input exceeded the authorised maximum");
        assertGt(taken.bond, 0, "no collateral taken");
        assertLe(taken.bond, plan.maxBondAmount, "collateral exceeded the hookData ceiling");

        assertEq(weth.balanceOf(DemoPoolParams.HOOK) - before.hookCollateral, taken.bond, "hook custody");

        _assertBondFields(opened, taken, openBlock, zeroForOne);

        console2.log("EO  quoted total input     ", plan.quotedTotalInput);
        console2.log("EO  amountInMaximum        ", uint256(plan.amountInMaximum));
        console2.log("EO  actual total spent     ", totalSpent);
        console2.log("EO  variableLeg (bWETH raw)", opened.variableLegAmount);
        console2.log("EO  collateral  (bWETH raw)", taken.bond);
    }

    /// @dev Shared bond-record assertions for the exact-output case.
    function _assertBondFields(Opened memory opened, Taken memory taken, uint256 openBlock, bool zeroForOne)
        internal
        view
    {
        BondMeBro.Bond memory bond = hook.getBond(opened.bondId);

        assertEq(bond.refundRecipient, trader, "refundRecipient must come from hookData");
        assertEq(opened.refundRecipient, trader, "event recipient");
        assertEq(bond.variableLegAmount, opened.variableLegAmount, "stored variable leg");
        assertGt(bond.collateralBps, 0, "collateralBps must be positive");
        assertEq(uint256(bond.openBlock), openBlock, "openBlock");
        assertEq(uint256(bond.maturityBlock), openBlock + 10, "maturityBlock must be open + 10");
        assertEq(uint256(bond.maturityBlock), uint256(opened.maturityBlock), "event maturity");
        assertEq(uint8(bond.state), STATE_FINALIZED, "state");
        assertEq(bond.collateralIsCurrency0, zeroForOne, "collateral side for exact output");
        assertEq(taken.bond, (uint256(bond.variableLegAmount) * bond.collateralBps) / hook.BPS(), "rate reconciliation");
        assertEq(hook.collateralAmountOf(opened.bondId), taken.bond, "collateralAmountOf");

        console2.log("EO  collateralBps          ", uint256(bond.collateralBps));
    }

    // ---------------------------------------------------------------------------------
    // 7. Maturity and permissionless settlement
    // ---------------------------------------------------------------------------------

    function test_settlement_isPermissionlessAndReconciles() public {
        (bytes32 bondId, uint128 collateral) = _openExactInputBond();
        BondMeBro.Bond memory bond = hook.getBond(bondId);

        // Settling before maturity must revert.
        vm.roll(bond.maturityBlock - 1);
        vm.prank(settler);
        vm.expectRevert(
            abi.encodeWithSelector(
                BondMeBro.BondNotMature.selector, bondId, bond.maturityBlock, uint256(bond.maturityBlock - 1)
            )
        );
        hook.settleBond(bondId);

        // Exactly at maturity, ten blocks after opening.
        vm.roll(bond.maturityBlock);
        assertEq(uint256(bond.maturityBlock), uint256(bond.openBlock) + 10, "maturity horizon");

        uint256 recipientBefore = weth.balanceOf(trader);
        uint256 hookBefore = weth.balanceOf(DemoPoolParams.HOOK);
        uint256 potBefore = hook.insurancePot(poolId, Currency.wrap(address(weth)));
        uint256 settlerBefore = weth.balanceOf(settler);

        // A THIRD PARTY settles. Not the refund recipient, not the pool owner.
        assertTrue(settler != trader && settler != owner, "settler must be unrelated");
        vm.recordLogs();
        vm.prank(settler);
        hook.settleBond(bondId);

        Settled memory s = _findBondSettled(vm.getRecordedLogs(), bondId);
        assertTrue(s.found, "BondSettled not emitted");

        // refund + slash == collateral, exactly.
        assertEq(s.collateral, collateral, "settled collateral differs from the taken amount");
        assertEq(uint256(s.refund) + uint256(s.slash), uint256(s.collateral), "refund + slash != collateral");

        // The refund goes to the STORED recipient, never the caller.
        assertEq(weth.balanceOf(trader) - recipientBefore, s.refund, "refund did not reach the stored recipient");
        assertEq(weth.balanceOf(settler), settlerBefore, "settler must not be paid");

        // The retained amount stays in the hook, credited to the pool's insurance reserve.
        assertEq(hookBefore - weth.balanceOf(DemoPoolParams.HOOK), s.refund, "hook released more than the refund");
        assertEq(
            hook.insurancePot(poolId, Currency.wrap(address(weth))) - potBefore,
            s.slash,
            "reserve did not receive the slash"
        );

        assertEq(uint8(hook.getBond(bondId).state), STATE_SETTLED, "bond should be SETTLED");

        // Original collateral is retained for the record and is NOT remaining liability.
        assertEq(hook.collateralAmountOf(bondId), collateral, "collateralAmountOf changed after settlement");

        // Settling twice must fail.
        vm.prank(settler);
        vm.expectRevert(abi.encodeWithSelector(BondMeBro.BondNotSettleable.selector, bondId, STATE_SETTLED));
        hook.settleBond(bondId);

        console2.log("SETTLE collateral", uint256(s.collateral));
        console2.log("SETTLE refund    ", uint256(s.refund));
        console2.log("SETTLE slash     ", uint256(s.slash));
        console2.log("SETTLE slashBps  ", uint256(s.slashBps));
    }

    // ---------------------------------------------------------------------------------
    // 8. Post-maturity immutability
    // ---------------------------------------------------------------------------------

    /// @dev The observation checkpoints are fixed at open+6, +8 and +10. Once maturity has
    /// passed, later trading must not be able to change what settlement pays. The same bond
    /// is settled twice from the same starting state: once on a quiet pool, once after a
    /// large price move. The two results must be identical.
    function test_settlementResultIsUnchangedByPostMaturityTrading() public {
        (bytes32 bondId,) = _openExactInputBond();
        BondMeBro.Bond memory bond = hook.getBond(bondId);

        // Push the price back before the checkpoints so the settlement being compared has a
        // NON-ZERO refund. Comparing two full slashes would pass even if the refund term
        // were broken.
        _counterTrade();

        vm.roll(bond.maturityBlock + 1);
        uint256 snapshot = vm.snapshotState();

        // Path A: settle on a quiet pool.
        vm.recordLogs();
        vm.prank(settler);
        hook.settleBond(bondId);
        Settled memory quiet = _findBondSettled(vm.getRecordedLogs(), bondId);
        assertTrue(quiet.found, "quiet settlement produced no event");

        vm.revertToState(snapshot);

        // Path B: move the pool hard AFTER maturity, then settle.
        (, int24 tickBefore,,) = poolManager.getSlot0(poolId);
        uint128 shove = uint128(200_000 * 10 ** DemoPoolParams.USDC_DECIMALS);
        vm.startPrank(trader);
        _approveThroughPermit2(address(usdc), DemoPoolParams.UNIVERSAL_ROUTER, shove);
        _swapExactInput(usdcIsCurrency0, shove, 0, _hookDataV2(trader, type(uint128).max));
        vm.stopPrank();
        (, int24 tickAfter,,) = poolManager.getSlot0(poolId);
        assertTrue(tickAfter != tickBefore, "post-maturity swap did not move the pool");

        vm.recordLogs();
        vm.prank(settler);
        hook.settleBond(bondId);
        Settled memory moved = _findBondSettled(vm.getRecordedLogs(), bondId);
        assertTrue(moved.found, "post-move settlement produced no event");

        assertEq(moved.collateral, quiet.collateral, "collateral changed after post-maturity trading");
        assertEq(moved.refund, quiet.refund, "refund changed after post-maturity trading");
        assertEq(moved.slash, quiet.slash, "slash changed after post-maturity trading");
        assertEq(moved.slashBps, quiet.slashBps, "slashBps changed after post-maturity trading");
        assertGt(quiet.refund, 0, "comparison is vacuous unless the refund is non-zero");

        console2.log("IMMUTABLE tick before post-maturity swap", int256(tickBefore));
        console2.log("IMMUTABLE tick after  post-maturity swap", int256(tickAfter));
        console2.log("IMMUTABLE refund quiet / moved", uint256(quiet.refund), uint256(moved.refund));
    }

    /// @dev A quiet pool never gives a refund: the opening move is still there at every
    /// checkpoint, so the whole collateral is retained. That is correct, but it leaves the
    /// refund path unexercised. Here the price is pushed BACK before the checkpoints, which
    /// is the case the mechanism exists to reward.
    function test_settlement_refundsWhenTheMoveReverts() public {
        (bytes32 bondId, uint128 collateral) = _openExactInputBond();
        BondMeBro.Bond memory bond = hook.getBond(bondId);

        (, int24 tickAfterOpen,,) = poolManager.getSlot0(poolId);
        _counterTrade();
        (, int24 tickAfterCounter,,) = poolManager.getSlot0(poolId);

        // The counter-trade must actually undo most of the opening move, or this proves
        // nothing about the refund path.
        assertLt(tickAfterCounter, tickAfterOpen, "counter-trade did not push the price back");

        vm.roll(bond.maturityBlock);

        uint256 recipientBefore = weth.balanceOf(trader);
        uint256 potBefore = hook.insurancePot(poolId, Currency.wrap(address(weth)));

        vm.recordLogs();
        vm.prank(settler);
        hook.settleBond(bondId);
        Settled memory s = _findBondSettled(vm.getRecordedLogs(), bondId);

        assertTrue(s.found, "BondSettled not emitted");
        assertEq(s.collateral, collateral, "collateral");
        assertEq(uint256(s.refund) + uint256(s.slash), uint256(s.collateral), "refund + slash != collateral");

        // THE POINT OF THIS TEST: a reverted move produces a real refund.
        assertGt(s.refund, 0, "a reverted price move should refund something");
        assertEq(weth.balanceOf(trader) - recipientBefore, s.refund, "refund did not reach the stored recipient");
        assertEq(hook.insurancePot(poolId, Currency.wrap(address(weth))) - potBefore, s.slash, "reserve credit");
        assertEq(uint8(hook.getBond(bondId).state), STATE_SETTLED, "bond should be SETTLED");

        console2.log("REFUND tick after open   ", int256(tickAfterOpen));
        console2.log("REFUND tick after counter", int256(tickAfterCounter));
        console2.log("REFUND collateral        ", uint256(s.collateral));
        console2.log("REFUND refunded          ", uint256(s.refund));
        console2.log("REFUND retained          ", uint256(s.slash));
        console2.log("REFUND slashBps          ", uint256(s.slashBps));
    }

    /// @dev Sells bWETH back into the pool to undo the opening move before the checkpoints.
    function _counterTrade() internal {
        uint128 amountIn = uint128(39 * 10 ** (DemoPoolParams.WETH_DECIMALS - 1));

        vm.startPrank(trader);
        _approveThroughPermit2(address(weth), DemoPoolParams.UNIVERSAL_ROUTER, amountIn);
        _swapExactInput(!usdcIsCurrency0, amountIn, 0, _hookDataV2(trader, type(uint128).max));
        vm.stopPrank();
    }

    /// @dev Opens one bonded exact-input bond and returns its id and collateral.
    function _openExactInputBond() internal returns (bytes32 bondId, uint128 collateral) {
        uint128 amountIn = uint128(10_000 * 10 ** DemoPoolParams.USDC_DECIMALS);

        vm.startPrank(trader);
        _approveThroughPermit2(address(usdc), DemoPoolParams.UNIVERSAL_ROUTER, amountIn);
        vm.recordLogs();
        _swapExactInput(usdcIsCurrency0, amountIn, 0, _hookDataV2(trader, type(uint128).max));
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        Opened memory opened = _findBondOpened(logs);
        Taken memory taken = _findBondTaken(logs);
        require(opened.found && taken.found, "rehearsal: swap did not bond");

        return (opened.bondId, uint128(taken.bond));
    }
}

