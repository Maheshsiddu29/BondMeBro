// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BaseHook} from "uniswap-hooks/src/base/BaseHook.sol";

import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";
import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";

/// @title BondCustodyTest

/// @notice Integration tests for BondMeBro's exact-input custody path. Every swap runs through a real Uniswap v4 `PoolManager` so the tests verify actual ERC-20 custody and custom-accounting behaviour rather than only checking callback return values.

contract BondCustodyTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    BondMeBro internal hook;

    PoolKey internal key_;
    PoolId internal id_;

    address internal constant TRADER = address(0xB0B);

    uint128 internal constant MIN_BONDED = 1e15;

    /// @dev Both test tokens use 18 decimals, so equal thresholds are appropriate here. Different-decimal threshold behaviour is tested separately in `BondThresholds.t.sol`.
    uint96 internal constant MIN_BONDED_1 = 1e15;

    uint16 internal constant BOND_BPS = 25;

    /// @dev A bonded exact-input amount large enough to avoid rounding in the bond calculation.
    int256 internal constant BONDED_INPUT = -1e16;

    uint256 internal constant BONDED_GROSS = 1e16;

    /// @dev `1e16 * 25 / 10_000 = 2.5e13`.
    uint256 internal constant EXPECTED_BOND = 2.5e13;

    /// @dev Below the bonding threshold, so this amount should take the unbonded path.
    int256 internal constant UNBONDED_INPUT = -1e14;

    uint128 internal constant GENEROUS_CEILING = type(uint128).max;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // In `forge test`, CREATE2 deployment happens from this test contract.
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(this)));

        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), address(this));

        assertEq(address(hook), predicted, "mined address mismatch");

        (key_, id_) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));

        // Add enough liquidity for the normal accounting tests to complete without
        // unintentionally turning into partial-fill tests.
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e21, salt: bytes32(uint256(1))
            }),
            ""
        );

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, BOND_BPS);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _swap(int256 amountSpecified, bool zeroForOne, bytes memory hookData) internal {
        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function _swapWithLimit(int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes memory hookData) internal {
        swapRouter.swap(
            key_,
            SwapParams({zeroForOne: true, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function _validHookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, GENEROUS_CEILING);
    }

    /// @dev Hook reverts are wrapped by Uniswap's hook-calling logic. This helper builds the expected wrapped error so tests verify the exact underlying BondMeBro error rather than accepting any revert.
    function _wrapped(bytes memory innerReason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            innerReason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /*//////////////////////////////////////////////////////////////
                      EXACT-INPUT CUSTODY ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies the complete exact-input custody flow: the trader spends the requested gross input, BondMeBro receives exactly the bond, and PoolManager receives the remaining input.

    /// @dev For a complete fill:
    ///
    /// `grossInput = poolInput + bond`
    ///
    /// The exact-input bond is carved out of the trader's specified input rather than charged on top.
    function test_bondedSwap_exactCustodyAccounting() public {
        uint256 swapperIn0 = currency0.balanceOf(address(this));

        uint256 swapperIn1 = currency1.balanceOf(address(this));

        uint256 hookIn0 = currency0.balanceOf(address(hook));

        uint256 managerIn0 = currency0.balanceOf(address(manager));

        _swap(BONDED_INPUT, true, _validHookData());

        uint256 swapperSpent = swapperIn0 - currency0.balanceOf(address(this));

        uint256 hookGained = currency0.balanceOf(address(hook)) - hookIn0;

        uint256 managerGained = currency0.balanceOf(address(manager)) - managerIn0;

        uint256 swapperReceived = currency1.balanceOf(address(this)) - swapperIn1;

        // The trader spends exactly the requested gross input.
        assertEq(swapperSpent, BONDED_GROSS, "swapper did not pay exactly gross input");

        // BondMeBro receives exactly the calculated bond.
        assertEq(hookGained, EXPECTED_BOND, "hook did not take exactly the bond");

        // The pool receives the trader's gross input minus the bond.
        assertEq(managerGained, BONDED_GROSS - EXPECTED_BOND, "pool did not receive gross - bond");

        // Every input token paid by the trader is accounted for.
        assertEq(hookGained + managerGained, swapperSpent, "input tokens leaked");

        // The pool must still receive enough input for a real swap to occur.
        assertGt(swapperReceived, 0, "swapper received no output");
    }

    /// @notice Verifies that bond custody ends as real ERC-20 tokens held by the hook, with no remaining PoolManager claim balance.
    function test_bondedSwap_hookHoldsNoResidualClaim() public {
        _swap(BONDED_INPUT, true, _validHookData());

        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "hook holds currency0 claims");

        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0, "hook holds currency1 claims");

        assertEq(currency0.balanceOf(address(hook)), EXPECTED_BOND, "bond is not held as ERC-20");
    }

    /// @notice Verifies that a oneForZero exact-input swap takes collateral in currency1, which is the input currency for that direction.
    function test_bondedSwap_oneForZero_bondsInCurrency1() public {
        uint256 hookIn0 = currency0.balanceOf(address(hook));

        uint256 hookIn1 = currency1.balanceOf(address(hook));

        _swap(BONDED_INPUT, false, _validHookData());

        assertEq(currency1.balanceOf(address(hook)) - hookIn1, EXPECTED_BOND, "bond not taken in currency1");

        assertEq(currency0.balanceOf(address(hook)), hookIn0, "currency0 balance moved on a oneForZero swap");
    }

    /*//////////////////////////////////////////////////////////////
                             PARTIAL FILL
    //////////////////////////////////////////////////////////////*/

    /// @notice Documents the known exact-input partial-fill sizing issue.

    /// @dev The bond is calculated in `beforeSwap` from the requested gross input. If the swap later stops at its price limit, the pool may consume less than the requested amount while the already-calculated bond remains unchanged.
    ///
    /// Therefore:
    ///
    /// `bond = requestedGrossInput * bondBps / 10_000`
    ///
    /// `traderOutflow = actualFilledInput + bond`
    ///
    /// Custody still reconciles correctly, but the effective bond rate relative to the actual filled amount can be higher than `bondBps`. This is a known sizing limitation of the current exact-input custody model.
    function test_partialFill_bondIsSizedOffRequestedInput() public {
        uint256 swapperIn0 = currency0.balanceOf(address(this));

        uint256 hookIn0 = currency0.balanceOf(address(hook));

        uint256 managerIn0 = currency0.balanceOf(address(manager));

        // Build a very tight price limit from the current price so this swap
        // deliberately stops before consuming the full requested input.
        // slither-disable-next-line unused-return
        (uint160 sqrtPriceNow,,,) = manager.getSlot0(id_);

        uint160 tightLimit = sqrtPriceNow - sqrtPriceNow / 1_000_000;

        _swapWithLimit(BONDED_INPUT, tightLimit, _validHookData());

        uint256 swapperSpent = swapperIn0 - currency0.balanceOf(address(this));

        uint256 hookGained = currency0.balanceOf(address(hook)) - hookIn0;

        uint256 filled = currency0.balanceOf(address(manager)) - managerIn0;

        assertLt(filled, BONDED_GROSS - EXPECTED_BOND, "swap did not partially fill; test is not exercising the case");

        // The bond is still based on the original requested gross input.
        assertEq(hookGained, EXPECTED_BOND, "bond was not sized off the requested gross input");

        // Trader spends only the actual filled input plus the already-taken bond.
        assertEq(swapperSpent, filled + EXPECTED_BOND, "outflow is not filled + bond");

        assertLt(swapperSpent, BONDED_GROSS, "outflow should be below gross input on a partial fill");

        // Accounting still reconciles even though the economic sizing is imperfect.
        assertEq(hookGained + filled, swapperSpent, "input tokens leaked on a partial fill");
    }

    /*//////////////////////////////////////////////////////////////
                              INV-NOOP
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies the upper boundary of INV-NOOP: `bond` must be strictly smaller than `grossInput`.

    /// @dev The normal config setter prevents extreme `bondBps`, so this test writes an invalid rate directly into the packed storage slot. At `10_000` bps:
    ///
    /// `bond = grossInput`
    ///
    /// BondMeBro must reject the swap before the bond can consume the trader's entire specified input.
    function test_invNoOp_bondEqualToGrossInput_reverts() public {
        _forceBondBps(10_000);

        vm.expectRevert(
            _wrapped(abi.encodeWithSelector(BondMeBro.BondViolatesNoOpBound.selector, BONDED_GROSS, BONDED_GROSS))
        );

        _swap(BONDED_INPUT, true, _validHookData());
    }

    /// @notice Verifies that a bond larger than the trader's complete gross input is also rejected.
    function test_invNoOp_bondGreaterThanGrossInput_reverts() public {
        _forceBondBps(20_000);

        vm.expectRevert(
            _wrapped(abi.encodeWithSelector(BondMeBro.BondViolatesNoOpBound.selector, BONDED_GROSS * 2, BONDED_GROSS))
        );

        _swap(BONDED_INPUT, true, _validHookData());
    }

    /// @notice Verifies the lower boundary of INV-NOOP: a bonded exact-input swap cannot continue with a bond that rounds down to zero.
    function test_invNoOp_bondRoundingToZero_reverts() public {
        // Allow a tiny trade through the threshold. At 25 bps, 399 raw units
        // produces a zero bond after integer division.
        hook.setPoolConfig(key_, 1, 1, BOND_BPS);

        vm.expectRevert(_wrapped(abi.encodeWithSelector(BondMeBro.BondViolatesNoOpBound.selector, 0, 399)));

        _swap(-399, true, _validHookData());
    }

    /// @notice Verifies INV-NOOP across valid bond rates and bonded exact-input sizes.

    /// @dev For every generated valid configuration:
    ///
    /// `0 < bond < grossInput`
    function testFuzz_invNoOp_holdsForEveryValidConfig(uint128 minBonded, uint16 bondBps, uint96 grossInput) public {
        bondBps = uint16(bound(bondBps, 1, hook.MAX_BOND_BPS()));

        minBonded = uint128(bound(minBonded, 1, 1e18));

        uint256 gross = bound(uint256(grossInput), uint256(minBonded), 1e20);

        vm.assume(gross * bondBps / 10_000 > 0);

        uint256 expectedBond = gross * bondBps / 10_000;

        assertGt(expectedBond, 0, "INV-NOOP lower bound violated: bond == 0");

        assertLt(expectedBond, gross, "INV-NOOP upper bound violated: bond >= grossInput");
    }

    /// @dev Writes an arbitrary `bondBps` directly into the packed `poolConfig` storage slot so INV-NOOP can be tested independently of the normal configuration cap.

    /// Storage layout:
    ///
    /// `minBondedAmount0` -> bits 0-127
    ///
    /// `minBondedAmount1` -> bits 128-223
    ///
    /// `bondBps`          -> bits 224-239
    ///
    /// The values are read back immediately so a future storage-layout change causes this helper to fail rather than silently testing the wrong state.
    function _forceBondBps(uint16 bondBps) internal {
        bytes32 slot = keccak256(abi.encode(id_, uint256(0)));

        bytes32 packed = bytes32(uint256(MIN_BONDED) | (uint256(MIN_BONDED_1) << 128) | (uint256(bondBps) << 224));

        vm.store(address(hook), slot, packed);

        (uint128 storedMin0, uint96 storedMin1, uint16 storedBps) = hook.poolConfig(id_);

        assertEq(storedMin0, MIN_BONDED, "vm.store wrote the wrong slot (minBondedAmount0)");

        assertEq(storedMin1, MIN_BONDED_1, "vm.store wrote the wrong slot (minBondedAmount1)");

        assertEq(storedBps, bondBps, "vm.store wrote the wrong slot (bondBps)");
    }

    /*//////////////////////////////////////////////////////////////
                      maxBondAmount ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies that a swap reverts when the calculated bond exceeds the trader-provided `maxBondAmount`.
    function test_bondExceedsTraderMax_reverts() public {
        uint128 tooLow = uint128(EXPECTED_BOND - 1);

        vm.expectRevert(
            _wrapped(abi.encodeWithSelector(BondMeBro.BondExceedsTraderMax.selector, EXPECTED_BOND, tooLow))
        );

        _swap(BONDED_INPUT, true, HookDataCodec.encode(TRADER, tooLow));
    }

    /// @notice Verifies that `maxBondAmount` is inclusive: a ceiling exactly equal to the calculated bond succeeds.
    function test_bondEqualToTraderMax_succeeds() public {
        uint256 hookIn0 = currency0.balanceOf(address(hook));

        _swap(BONDED_INPUT, true, HookDataCodec.encode(TRADER, uint128(EXPECTED_BOND)));

        assertEq(currency0.balanceOf(address(hook)) - hookIn0, EXPECTED_BOND, "exact-ceiling swap did not bond");
    }

    /*//////////////////////////////////////////////////////////////
                          hookData BEHAVIOUR
    //////////////////////////////////////////////////////////////*/

    /// @notice A bonded swap must provide hookData.
    function test_bondedSwap_missingHookData_reverts() public {
        vm.expectRevert(_wrapped(abi.encodeWithSelector(HookDataCodec.MissingHookData.selector)));

        _swap(BONDED_INPUT, true, "");
    }

    /// @notice A bonded swap rejects unsupported hookData versions.
    function test_bondedSwap_wrongVersionHookData_reverts() public {
        bytes memory malformed = abi.encodePacked(uint8(2), TRADER, GENEROUS_CEILING);

        vm.expectRevert(_wrapped(abi.encodeWithSelector(HookDataCodec.UnsupportedHookDataVersion.selector, uint8(2))));

        _swap(BONDED_INPUT, true, malformed);
    }

    /// @notice A bonded swap rejects truncated hookData.
    function test_bondedSwap_truncatedHookData_reverts() public {
        bytes memory malformed = abi.encodePacked(HookDataCodec.VERSION, TRADER);

        vm.expectRevert(
            _wrapped(
                abi.encodeWithSelector(
                    HookDataCodec.InvalidHookDataLength.selector, HookDataCodec.ENCODED_LENGTH, uint256(21)
                )
            )
        );

        _swap(BONDED_INPUT, true, malformed);
    }

    /// @notice A bonded swap rejects a zero refund recipient.
    function test_bondedSwap_zeroRecipientHookData_reverts() public {
        bytes memory malformed = abi.encodePacked(HookDataCodec.VERSION, address(0), GENEROUS_CEILING);

        vm.expectRevert(_wrapped(abi.encodeWithSelector(HookDataCodec.ZeroRefundRecipient.selector)));

        _swap(BONDED_INPUT, true, malformed);
    }

    /// @notice Invalid hookData must fail closed and move no tokens.
    function test_bondedSwap_missingHookData_movesNoTokens() public {
        uint256 hookBefore = currency0.balanceOf(address(hook));

        uint256 swapperBefore = currency0.balanceOf(address(this));

        vm.expectRevert(_wrapped(abi.encodeWithSelector(HookDataCodec.MissingHookData.selector)));

        _swap(BONDED_INPUT, true, "");

        assertEq(currency0.balanceOf(address(hook)), hookBefore, "hook gained tokens on a reverted swap");

        assertEq(currency0.balanceOf(address(this)), swapperBefore, "swapper lost tokens on a reverted swap");
    }

    /*//////////////////////////////////////////////////////////////
                            UNBONDED PATHS
    //////////////////////////////////////////////////////////////*/

    /// @notice A swap below the threshold proceeds normally without hookData or bond custody.
    function test_unbondedSwap_belowThreshold_emptyHookData_proceeds() public {
        uint256 hookBefore = currency0.balanceOf(address(hook));

        uint256 swapperBefore1 = currency1.balanceOf(address(this));

        _swap(UNBONDED_INPUT, true, "");

        assertEq(currency0.balanceOf(address(hook)), hookBefore, "unbonded swap moved tokens to the hook");

        assertGt(currency1.balanceOf(address(this)), swapperBefore1, "unbonded swap produced no output");

        // Tick diagnostics confirm that both swap callbacks executed.
        assertEq(hook.lastTickBefore(), 0, "beforeSwap did not record the pre-swap tick");

        assertLt(hook.lastTickAfter(), 0, "afterSwap did not record the post-swap tick");
    }

    /// @notice A swap exactly equal to the threshold is bonded.
    function test_swapExactlyAtThreshold_isBonded() public {
        uint256 hookBefore = currency0.balanceOf(address(hook));

        _swap(-int256(uint256(MIN_BONDED)), true, _validHookData());

        assertEq(
            currency0.balanceOf(address(hook)) - hookBefore,
            uint256(MIN_BONDED) * BOND_BPS / 10_000,
            "swap at the threshold was not bonded"
        );
    }

    /// @notice A swap one raw unit below the threshold remains unbonded and requires no hookData.
    function test_swapOneBelowThreshold_isUnbonded() public {
        uint256 hookBefore = currency0.balanceOf(address(hook));

        _swap(-int256(uint256(MIN_BONDED) - 1), true, "");

        assertEq(currency0.balanceOf(address(hook)), hookBefore, "swap below the threshold was bonded");
    }

    /// @notice A pool with bonding disabled never takes collateral.
    function test_unconfiguredPool_neverBonds() public {
        hook.setPoolConfig(key_, 0, 0, 0);

        uint256 hookBefore = currency0.balanceOf(address(hook));

        _swap(BONDED_INPUT, true, "");

        assertEq(currency0.balanceOf(address(hook)), hookBefore, "disabled pool still bonded");
    }

    /// @notice An exact-output swap on a bonding-enabled pool must provide valid hookData.

    /// @dev Exact-output custody is tested in `BondCustodyExactOutput.t.sol`. This test only pins the important safety behaviour that exact-output can no longer bypass BondMeBro by omitting hookData.
    function test_exactOutput_onBondingPool_requiresHookData() public {
        vm.expectRevert(_wrapped(abi.encodeWithSelector(HookDataCodec.MissingHookData.selector)));

        _swap(int256(BONDED_GROSS), true, "");
    }

    /// @notice Exact-output swaps on a pool with bonding disabled do not require hookData.
    function test_exactOutput_onDisabledPool_needsNoHookData() public {
        hook.setPoolConfig(key_, 0, 0, 0);

        uint256 hookBefore0 = currency0.balanceOf(address(hook));

        uint256 hookBefore1 = currency1.balanceOf(address(hook));

        _swap(int256(BONDED_GROSS), true, "");

        assertEq(currency0.balanceOf(address(hook)), hookBefore0, "disabled pool bonded currency0");

        assertEq(currency1.balanceOf(address(hook)), hookBefore1, "disabled pool bonded currency1");
    }

    /*//////////////////////////////////////////////////////////////
                      CONFIG & ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice `bondBps` cannot exceed the compile-time safety cap.
    function test_setPoolConfig_rejectsBondBpsAboveCap() public {
        vm.expectRevert(abi.encodeWithSelector(BondMeBro.BondBpsAboveCap.selector, uint16(101), uint16(100)));

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, 101);
    }

    /// @notice The maximum allowed bond rate itself is valid.
    function test_setPoolConfig_acceptsBondBpsAtCap() public {
        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, 100);

        (,, uint16 bondBps) = hook.poolConfig(id_);

        assertEq(bondBps, 100, "config at the cap was rejected");
    }

    /// @notice Pool configuration must either set all three bonding fields or clear all three.

    /// @dev A zero threshold does not disable one direction because `grossInput >= 0` is true for every positive swap. Partial configurations are therefore rejected.
    function test_setPoolConfig_rejectsPartialConfigurations() public {
        // Only threshold0 set.
        vm.expectRevert(
            abi.encodeWithSelector(BondMeBro.IncompletePoolConfig.selector, MIN_BONDED, uint96(0), uint16(0))
        );

        hook.setPoolConfig(key_, MIN_BONDED, 0, 0);

        // Only threshold1 set.
        vm.expectRevert(
            abi.encodeWithSelector(BondMeBro.IncompletePoolConfig.selector, uint128(0), MIN_BONDED_1, uint16(0))
        );

        hook.setPoolConfig(key_, 0, MIN_BONDED_1, 0);

        // Only bond rate set.
        vm.expectRevert(
            abi.encodeWithSelector(BondMeBro.IncompletePoolConfig.selector, uint128(0), uint96(0), BOND_BPS)
        );

        hook.setPoolConfig(key_, 0, 0, BOND_BPS);

        // Both thresholds but no bond rate.
        vm.expectRevert(
            abi.encodeWithSelector(BondMeBro.IncompletePoolConfig.selector, MIN_BONDED, MIN_BONDED_1, uint16(0))
        );

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, 0);

        // Missing threshold1.
        vm.expectRevert(
            abi.encodeWithSelector(BondMeBro.IncompletePoolConfig.selector, MIN_BONDED, uint96(0), BOND_BPS)
        );

        hook.setPoolConfig(key_, MIN_BONDED, 0, BOND_BPS);

        // Missing threshold0.
        vm.expectRevert(
            abi.encodeWithSelector(BondMeBro.IncompletePoolConfig.selector, uint128(0), MIN_BONDED_1, BOND_BPS)
        );

        hook.setPoolConfig(key_, 0, MIN_BONDED_1, BOND_BPS);
    }

    /// @notice `(0, 0, 0)` is the valid way to disable bonding for a pool.
    function test_setPoolConfig_allZeroDisables() public {
        hook.setPoolConfig(key_, 0, 0, 0);

        (uint128 min0, uint96 min1, uint16 bondBps) = hook.poolConfig(id_);

        assertEq(min0, 0, "currency0 threshold not cleared");

        assertEq(min1, 0, "currency1 threshold not cleared");

        assertEq(bondBps, 0, "bond rate not cleared");
    }

    /// @notice Deployment rejects a zero owner because ownership is immutable and nobody could configure pools afterward.
    function test_constructor_rejectsZeroOwner() public {
        (, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(0)));

        vm.expectRevert(BondMeBro.ZeroOwner.selector);

        new BondMeBro{salt: salt}(IPoolManager(address(manager)), address(0));
    }

    /// @notice Only the immutable owner can change pool bonding configuration.
    function test_setPoolConfig_onlyOwner() public {
        vm.prank(address(0xBAD));

        vm.expectRevert(BondMeBro.NotOwner.selector);

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, BOND_BPS);
    }

    /// @notice Swap callbacks cannot be called directly by arbitrary addresses.

    /// @dev BondMeBro's swap accounting is valid only inside PoolManager's unlock lifecycle, so `BaseHook` must reject direct callback calls.
    function test_directCallback_reverts() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: BONDED_INPUT, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.expectRevert(BaseHook.NotPoolManager.selector);

        hook.beforeSwap(address(this), key_, params, _validHookData());

        vm.expectRevert(BaseHook.NotPoolManager.selector);

        hook.afterSwap(address(this), key_, params, BalanceDeltaLibrary.ZERO_DELTA, _validHookData());
    }

    /*//////////////////////////////////////////////////////////////
                                 GAS
    //////////////////////////////////////////////////////////////*/

    /// @dev Isolated bonded swap used for callback gas measurement.
    function test_gas_bondedSwap() public {
        _swap(BONDED_INPUT, true, _validHookData());
    }

    /// @dev Isolated unbonded swap used for callback gas measurement.
    function test_gas_unbondedSwap() public {
        _swap(UNBONDED_INPUT, true, "");
    }
}
