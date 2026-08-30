// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";
import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";

/// @title BondThresholdsTest

/// @notice Tests BondMeBro's separate bonding thresholds for currency0 and currency1.

/// @dev Each swap direction has a different input currency, so one raw-unit threshold cannot correctly represent both sides of every pool. This suite uses tokens with 6 and 18 decimals so a bug that accidentally uses the same threshold in both directions is easy to detect.

contract BondThresholdsTest is Test, Deployers {
    BondMeBro internal hook;

    PoolKey internal key_;
    PoolId internal id_;

    MockERC20 internal token0;
    MockERC20 internal token1;

    uint8 internal dec0;
    uint8 internal dec1;

    address internal constant TRADER = address(0xB0B);

    uint128 internal constant GENEROUS_CEILING = type(uint128).max;

    uint16 internal constant BOND_BPS = 25;

    /// @dev Independent raw-unit thresholds for the two input currencies.
    uint128 internal constant THRESHOLD_0 = 1e6;
    uint96 internal constant THRESHOLD_1 = 1e18;

    /// @dev The same raw amount sits above threshold0 but below threshold1, so it should bond in only one direction.
    uint256 internal constant STRADDLING_AMOUNT = 1e7;

    function setUp() public {
        deployFreshManagerAndRouters();

        // Use tokens with different decimals so threshold-selection mistakes
        // cannot hide behind symmetric test currencies.
        MockERC20 sixDec = new MockERC20("SixDecimal", "SIX", 6);

        MockERC20 eighteenDec = new MockERC20("EighteenDecimal", "EIGHTEEN", 18);

        (token0, token1) = address(sixDec) < address(eighteenDec) ? (sixDec, eighteenDec) : (eighteenDec, sixDec);

        dec0 = token0.decimals();
        dec1 = token1.decimals();

        assertTrue(dec0 != dec1, "the whole point of this suite is asymmetric decimals");

        currency0 = Currency.wrap(address(token0));

        currency1 = Currency.wrap(address(token1));

        token0.mint(address(this), 1e30);

        token1.mint(address(this), 1e30);

        token0.approve(address(swapRouter), type(uint256).max);

        token1.approve(address(swapRouter), type(uint256).max);

        token0.approve(address(modifyLiquidityRouter), type(uint256).max);

        token1.approve(address(modifyLiquidityRouter), type(uint256).max);

        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(this)));

        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), address(this));

        assertEq(address(hook), predicted, "mined address mismatch");

        // Tick 0 gives a 1:1 raw-unit price. That is not meant to model a real
        // 6-decimal/18-decimal market; it keeps execution symmetric so the tests
        // isolate threshold selection.
        (key_, id_) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));

        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e21, salt: bytes32(uint256(1))
            }),
            ""
        );

        hook.setPoolConfig(key_, THRESHOLD_0, THRESHOLD_1, BOND_BPS);
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

    function _validHookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, GENEROUS_CEILING);
    }

    /// @dev Executes a swap and returns the real bond received by BondMeBro in that swap's input currency.
    function _bondTakenBy(int256 amountSpecified, bool zeroForOne, bytes memory hookData) internal returns (uint256) {
        Currency inputCurrency = zeroForOne ? currency0 : currency1;

        uint256 beforeBalance = inputCurrency.balanceOf(address(hook));

        _swap(amountSpecified, zeroForOne, hookData);

        return inputCurrency.balanceOf(address(hook)) - beforeBalance;
    }

    /*//////////////////////////////////////////////////////////////
                       DIRECTION-SPECIFIC THRESHOLDS
    //////////////////////////////////////////////////////////////*/

    /// @notice The same raw input amount can be bonded in one direction and unbonded in the other because each input currency has its own threshold.

    /// @dev `STRADDLING_AMOUNT` satisfies:
    ///
    /// `STRADDLING_AMOUNT >= THRESHOLD_0`
    ///
    /// `STRADDLING_AMOUNT < THRESHOLD_1`
    ///
    /// A hook that ignores swap direction when choosing the threshold will fail this test.
    function test_sameNominalAmount_bondsOneDirectionOnly() public {
        uint256 bond0 = _bondTakenBy(-int256(STRADDLING_AMOUNT), true, _validHookData());

        assertGt(bond0, 0, "currency0-in swap above its threshold was not bonded");

        assertEq(bond0, STRADDLING_AMOUNT * BOND_BPS / 10_000, "currency0 bond is not bondBps of gross");

        uint256 bond1 = _bondTakenBy(-int256(STRADDLING_AMOUNT), false, "");

        assertEq(bond1, 0, "currency1-in swap below its threshold was bonded");

        console2.log("decimals0", dec0, "decimals1", dec1);
    }

    /*//////////////////////////////////////////////////////////////
                         EXACT-INPUT THRESHOLDS
    //////////////////////////////////////////////////////////////*/

    /// @notice For zeroForOne exact-input swaps, currency0 is the input and `THRESHOLD_0` must be used.
    function test_exactInput_zeroForOne_selectsThreshold0() public {
        assertEq(_bondTakenBy(-int256(uint256(THRESHOLD_0) - 1), true, ""), 0, "one wei below threshold0 was bonded");

        uint256 bond = _bondTakenBy(-int256(uint256(THRESHOLD_0)), true, _validHookData());

        assertEq(bond, uint256(THRESHOLD_0) * BOND_BPS / 10_000, "exactly at threshold0 was not bonded correctly");
    }

    /// @notice For oneForZero exact-input swaps, currency1 is the input and `THRESHOLD_1` must be used.
    function test_exactInput_oneForZero_selectsThreshold1() public {
        assertEq(_bondTakenBy(-1e17, false, ""), 0, "amount below threshold1 was bonded on the currency1 side");

        uint256 bond = _bondTakenBy(-int256(uint256(THRESHOLD_1)), false, _validHookData());

        assertEq(bond, uint256(THRESHOLD_1) * BOND_BPS / 10_000, "exactly at threshold1 was not bonded correctly");
    }

    /*//////////////////////////////////////////////////////////////
                        EXACT-OUTPUT THRESHOLDS
    //////////////////////////////////////////////////////////////*/

    /// @notice Exact-output zeroForOne swaps compare gross input against `THRESHOLD_0`.
    function test_exactOutput_zeroForOne_selectsThreshold0() public {
        uint256 bond = _bondTakenBy(int256(STRADDLING_AMOUNT), true, _validHookData());

        assertGt(bond, 0, "exact-output currency0-in above threshold0 was not bonded");
    }

    /// @notice Exact-output oneForZero swaps compare gross input against `THRESHOLD_1`.

    /// @dev Valid hookData is still required because exact-output does not know the final input amount before the pool executes.
    function test_exactOutput_oneForZero_selectsThreshold1() public {
        uint256 bond = _bondTakenBy(int256(STRADDLING_AMOUNT), false, _validHookData());

        assertEq(bond, 0, "exact-output currency1-in below threshold1 was bonded");
    }

    /// @notice The currency1 exact-output path starts bonding once its own threshold is exceeded.
    function test_exactOutput_oneForZero_bondsAboveThreshold1() public {
        uint256 bond = _bondTakenBy(int256(uint256(THRESHOLD_1) * 2), false, _validHookData());

        assertGt(bond, 0, "exact-output currency1-in above threshold1 was not bonded");
    }

    /*//////////////////////////////////////////////////////////////
                           uint96 BOUNDARY
    //////////////////////////////////////////////////////////////*/

    /// @notice The maximum `uint96` currency1 threshold can be stored without truncating or corrupting neighbouring packed fields.
    function test_setPoolConfig_acceptsMaxUint96Threshold() public {
        hook.setPoolConfig(key_, type(uint128).max, type(uint96).max, BOND_BPS);

        (uint128 min0, uint96 min1, uint16 bondBps) = hook.poolConfig(id_);

        assertEq(min1, type(uint96).max, "uint96 threshold was truncated");

        assertEq(min0, type(uint128).max, "neighbouring uint128 field was corrupted");

        assertEq(bondBps, BOND_BPS, "neighbouring uint16 field was corrupted");
    }

    /// @notice Raw calldata containing a value larger than `uint96` must be rejected rather than silently truncated.

    /// @dev Normal Solidity calls already enforce the parameter type at compile time. This test exercises manually encoded calldata, where the ABI decoder must reject dirty high bits before `setPoolConfig` executes.
    function test_setPoolConfig_rejectsOversizedThresholdViaRawCalldata() public {
        uint256 tooBig = uint256(type(uint96).max) + 1;

        bytes memory badCalldata = abi.encodeWithSelector(
            BondMeBro.setPoolConfig.selector, key_, uint256(THRESHOLD_0), tooBig, uint256(BOND_BPS)
        );

        (bool success,) = address(hook).call(badCalldata);

        assertFalse(success, "an oversized uint96 threshold was accepted through raw calldata");

        // Rejected calldata must leave the existing configuration unchanged.
        (uint128 min0, uint96 min1, uint16 bondBps) = hook.poolConfig(id_);

        assertEq(min0, THRESHOLD_0, "config was mutated by a rejected call");

        assertEq(min1, THRESHOLD_1, "config was mutated by a rejected call");

        assertEq(bondBps, BOND_BPS, "config was mutated by a rejected call");
    }

    /// @notice Equivalent raw calldata with an in-range `uint96` value succeeds.
    function test_setPoolConfig_rawCalldataWithinRangeSucceeds() public {
        bytes memory goodCalldata = abi.encodeWithSelector(
            BondMeBro.setPoolConfig.selector, key_, uint256(THRESHOLD_0), uint256(type(uint96).max), uint256(BOND_BPS)
        );

        (bool success,) = address(hook).call(goodCalldata);

        assertTrue(success, "a valid raw-calldata config was rejected");

        (, uint96 min1,) = hook.poolConfig(id_);

        assertEq(min1, type(uint96).max, "raw-calldata config did not take effect");
    }

    /*//////////////////////////////////////////////////////////////
                        SINGLE-SLOT CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies that adding the second threshold does not make `PoolConfig` spill into another storage slot.

    /// @dev `minBondedAmount0`, `minBondedAmount1`, and `bondBps` are intentionally packed into one 256-bit slot. The test checks which storage slots are touched rather than assuming a specific number of SLOAD opcodes, because compiler optimization can change how many reads are emitted without changing the storage layout.
    function test_configOccupiesOneSlot_exactInput() public {
        _assertConfigTouchesOnlyItsOwnSlot(-int256(STRADDLING_AMOUNT));
    }

    function test_configOccupiesOneSlot_exactOutput() public {
        _assertConfigTouchesOnlyItsOwnSlot(int256(STRADDLING_AMOUNT));
    }

    function _assertConfigTouchesOnlyItsOwnSlot(int256 amountSpecified) internal {
        bytes32 configSlot = keccak256(abi.encode(id_, uint256(0)));

        bytes32 spillSlot = bytes32(uint256(configSlot) + 1);

        vm.record();

        _swap(amountSpecified, true, _validHookData());

        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(hook));

        assertGt(_countMatches(reads, configSlot), 0, "the config slot was never read");

        assertEq(_countMatches(reads, spillSlot), 0, "config spilled into a second slot (read)");

        assertEq(_countMatches(writes, spillSlot), 0, "config spilled into a second slot (write)");
    }

    function _countMatches(bytes32[] memory values, bytes32 target) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < values.length; i++) {
            if (values[i] == target) {
                count++;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzzes threshold selection across independent currency0 and currency1 thresholds, swap sizes, and both directions.

    /// @dev The bonding decision must always use the threshold belonging to the actual input currency:
    ///
    /// `zeroForOne == true  -> minBondedAmount0`
    ///
    /// `zeroForOne == false -> minBondedAmount1`
    function testFuzz_thresholdSelectionFollowsInputCurrency(
        uint128 raw0,
        uint96 raw1,
        uint96 rawAmount,
        bool zeroForOne
    ) public {
        uint128 min0 = uint128(bound(uint256(raw0), 1, 1e15));

        uint96 min1 = uint96(bound(uint256(raw1), 1, 1e15));

        uint256 amount = bound(uint256(rawAmount), 1e6, 1e16);

        hook.setPoolConfig(key_, min0, min1, BOND_BPS);

        uint256 applicable = zeroForOne ? uint256(min0) : uint256(min1);

        bool shouldBond = amount >= applicable && (amount * BOND_BPS) / 10_000 > 0;

        // Supplying valid hookData is harmless on an unbonded exact-input swap
        // because the hook does not decode it unless the threshold is reached.
        uint256 bond = _bondTakenBy(-int256(amount), zeroForOne, _validHookData());

        if (shouldBond) {
            assertEq(bond, amount * BOND_BPS / 10_000, "bonded swap took the wrong bond");
        } else {
            assertEq(bond, 0, "swap below its own currency's threshold was bonded");
        }
    }
}
