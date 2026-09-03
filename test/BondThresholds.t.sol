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

import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";
import {ModelLReference} from "./utils/ModelLReference.sol";
import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";

/// @title BondThresholdsTest

/// @notice Tests BondMeBro's separate bonding thresholds for currency0 and currency1.

/// @dev Each swap direction has a different input currency, so one raw-unit threshold cannot correctly represent both sides of every pool. This suite uses tokens with 6 and 18 decimals so a bug that accidentally uses the same threshold in both directions is easy to detect.

contract BondThresholdsTest is Test, Deployers {
    using StateLibrary for IPoolManager;

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

    /// @dev Settlement noise floor, in ticks. Displacement at or below this is never slashed.
    uint16 internal constant REFUND_TOL = 5;

    /// @dev Independent raw-unit thresholds for the two input currencies.
    ///
    ///      THRESHOLD_1 CAME DOWN FROM 1e18 TO 1e9 IN P-L2-3/4, and the reason is a real new
    ///      constraint rather than convenience.
    ///
    ///      Model L sizes collateral from the realized tick impact, so a swap only bonds if it
    ///      actually moves the price. That ties every amount in this file to the pool's depth, and
    ///      the two ends now pull against each other:
    ///
    ///        THRESHOLD_0 = 1e6 must MOVE a tick   -> liquidity must be at or below ~2e10
    ///        THRESHOLD_1 = 1e18 must FILL         -> liquidity must be far above 1e10
    ///
    ///      No single pool satisfies both: 1e18 against 2e10 of liquidity is a swap a thousand
    ///      times the size of the pool. The twelve orders of magnitude between the thresholds were
    ///      never the point -- the point is that the two currencies have INDEPENDENT thresholds and
    ///      that direction selects between them. That property is preserved exactly by a narrower
    ///      spread, and the asymmetric token decimals which give the suite its name are untouched.
    uint128 internal constant THRESHOLD_0 = 1e6;
    uint96 internal constant THRESHOLD_1 = 1e9;

    /// @dev The same raw amount sits above threshold0 but below threshold1, so it should bond in only one direction.
    uint256 internal constant STRADDLING_AMOUNT = 1e7;

    /// @dev Sized so `THRESHOLD_0` (the smallest bonded amount here) still crosses a tick.
    ///
    ///      Measured on this fixture: at 1e10 a 1e6 swap moves ~2 ticks and a 1e9 swap moves far
    ///      past the 397-tick cap, so both ends of the threshold range produce a real, non-zero
    ///      Model L rate. At the old 1e21 every swap in this file moved zero ticks and therefore
    ///      bonded nothing, which is how this suite failed after the migration.
    int128 internal constant POOL_LIQUIDITY = 1e10;

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
        // `initPool`, NOT `initPoolAndAddLiquidity`.
        //
        // The convenience helper also installs `Deployers`' default position: 1e18 of liquidity in
        // a narrow band around tick 0. That is four to eight orders of magnitude deeper than this
        // suite needs, and it sits exactly where these swaps execute, so it would dominate the
        // price response completely and hold every swap in this file below one tick of impact --
        // bonding nothing. The pool is therefore initialized empty and given only the depth
        // deliberately chosen in `POOL_LIQUIDITY`.
        (key_, id_) = initPool(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));

        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: POOL_LIQUIDITY, salt: bytes32(uint256(1))
            }),
            ""
        );

        hook.setPoolConfig(key_, THRESHOLD_0, THRESHOLD_1, 10_000, 10_000, true);
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

    /// @dev Executes a swap and returns the real collateral received by BondMeBro, IN WHICHEVER
    ///      CURRENCY the swap's variable leg is denominated.
    ///
    ///      This helper used to watch the INPUT currency unconditionally, which was correct while
    ///      collateral always came out of the input. Under ADR-0006 the collateral currency depends
    ///      on the swap KIND as well as its direction, so for an exact-input swap it is the OUTPUT.
    ///      A helper still watching the input would report zero for every correctly bonded
    ///      exact-input swap in this file -- indistinguishable from "the threshold rejected it",
    ///      which is exactly the property the suite exists to measure.
    function _bondTakenBy(int256 amountSpecified, bool zeroForOne, bytes memory hookData) internal returns (uint256) {
        Currency collateralCurrency =
            ModelLReference.collateralIsCurrency0(zeroForOne, amountSpecified < 0) ? currency0 : currency1;

        Currency variableCurrency = amountSpecified < 0
            ? (zeroForOne ? currency1 : currency0)  // exact-input: the variable leg is the output
            : (zeroForOne ? currency0 : currency1); // exact-output: the variable leg is the input

        uint256 beforeBalance = collateralCurrency.balanceOf(address(hook));

        uint256 traderBefore = variableCurrency.balanceOf(address(this));
        uint256 managerBefore = variableCurrency.balanceOf(address(manager));

        _lastTickBefore = _tick();

        _swap(amountSpecified, zeroForOne, hookData);

        _lastTickAfter = _tick();

        uint256 taken = collateralCurrency.balanceOf(address(hook)) - beforeBalance;

        // The realized variable leg, reconstructed from balances.
        //
        //   exact-input  : the pool paid out `traderGain + bond`, since the hook withheld its
        //                  collateral from the output before the trader saw it.
        //   exact-output : the pool RECEIVED the leg, so it is the manager's gain.
        //
        // Recovering it from measured movement rather than from the hook's own record keeps the
        // sizing assertions independent of the thing they are checking.
        _lastLeg = amountSpecified < 0
            ? (variableCurrency.balanceOf(address(this)) - traderBefore) + taken
            : (variableCurrency.balanceOf(address(manager)) - managerBefore);

        return taken;
    }

    /// @dev Set by `_bondTakenBy` so callers can size the expected bond independently.
    uint256 internal _lastLeg;
    int24 internal _lastTickBefore;
    int24 internal _lastTickAfter;

    /// @dev The pool tick.
    function _tick() internal view returns (int24 tick) {
        // slither-disable-next-line unused-return
        (, tick,,) = manager.getSlot0(id_);
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

        // Sizing is asserted through the independent Model L reference rather than against
        // `bondBps`, which no longer determines the rate. The leg here is the OUTPUT, because
        // this is an exact-input swap.
        assertEq(
            bond0,
            ModelLReference.collateralFor(_lastLeg, _lastTickBefore, _lastTickAfter),
            "currency0-in bond does not match the Model L rate on the realized output"
        );

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

        assertGt(bond, 0, "exactly at threshold0 was not bonded");

        assertEq(
            bond,
            ModelLReference.collateralFor(_lastLeg, _lastTickBefore, _lastTickAfter),
            "the bond at threshold0 does not match the Model L rate"
        );
    }

    /// @notice For oneForZero exact-input swaps, currency1 is the input and `THRESHOLD_1` must be used.
    function test_exactInput_oneForZero_selectsThreshold1() public {
        assertEq(
            _bondTakenBy(-int256(uint256(THRESHOLD_1) - 1), false, ""),
            0,
            "amount below threshold1 was bonded on the currency1 side"
        );

        uint256 bond = _bondTakenBy(-int256(uint256(THRESHOLD_1)), false, _validHookData());

        assertGt(bond, 0, "exactly at threshold1 was not bonded");

        assertEq(
            bond,
            ModelLReference.collateralFor(_lastLeg, _lastTickBefore, _lastTickAfter),
            "the bond at threshold1 does not match the Model L rate"
        );
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
        hook.setPoolConfig(key_, type(uint128).max, type(uint96).max, 10_000, 10_000, true);

        (uint128 min0, uint96 min1, bool bondingEnabled,,) = hook.poolConfig(id_);

        assertEq(min1, type(uint96).max, "uint96 threshold was truncated");

        assertEq(min0, type(uint128).max, "neighbouring uint128 field was corrupted");

        assertTrue(bondingEnabled, "the neighbouring enable flag was corrupted");
    }

    /// @notice Raw calldata containing a value larger than `uint96` must be rejected rather than silently truncated.

    /// @dev Normal Solidity calls already enforce the parameter type at compile time. This test exercises manually encoded calldata, where the ABI decoder must reject dirty high bits before `setPoolConfig` executes.
    function test_setPoolConfig_rejectsOversizedThresholdViaRawCalldata() public {
        uint256 tooBig = uint256(type(uint96).max) + 1;

        bytes memory badCalldata = abi.encodeWithSelector(
            BondMeBro.setPoolConfig.selector, key_, uint256(THRESHOLD_0), tooBig, uint256(BOND_BPS), uint256(REFUND_TOL)
        );

        (bool success,) = address(hook).call(badCalldata);

        assertFalse(success, "an oversized uint96 threshold was accepted through raw calldata");

        // Rejected calldata must leave the existing configuration unchanged.
        (uint128 min0, uint96 min1, bool bondingEnabled,,) = hook.poolConfig(id_);

        assertEq(min0, THRESHOLD_0, "config was mutated by a rejected call");

        assertEq(min1, THRESHOLD_1, "config was mutated by a rejected call");

        assertTrue(bondingEnabled, "config was mutated by a rejected call");
    }

    /// @notice Equivalent raw calldata with an in-range `uint96` value succeeds.
    function test_setPoolConfig_rawCalldataWithinRangeSucceeds() public {
        bytes memory goodCalldata = abi.encodeWithSelector(
            BondMeBro.setPoolConfig.selector,
            key_,
            uint256(THRESHOLD_0),
            uint256(type(uint96).max),
            uint256(10_000), // minVariableLeg0, at the smallest accepted value
            uint256(10_000), // minVariableLeg1
            uint256(1) // bondingEnabled == true, ABI-encoded as a full word
        );

        (bool success,) = address(hook).call(goodCalldata);

        assertTrue(success, "a valid raw-calldata config was rejected");

        (, uint96 min1,,,) = hook.poolConfig(id_);

        assertEq(min1, type(uint96).max, "raw-calldata config did not take effect");
    }

    /*//////////////////////////////////////////////////////////////
                        SINGLE-SLOT CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice `PoolConfig` occupies exactly TWO storage slots on the swap path, and no more.
    ///
    /// @dev THIS TEST USED TO ASSERT ONE SLOT, and the change is deliberate rather than a
    ///      regression. The config gained two variable-leg minimums, which are amounts in the
    ///      collateral currency and need widths that cannot fit in the three spare bytes the first
    ///      slot had left. The cost is one extra storage read on a bonded swap, which was measured
    ///      against the callback ceilings before the change was accepted.
    ///
    ///      The property worth keeping is unchanged: the config must not creep into a THIRD slot.
    ///      The test therefore still watches for a spill, one slot further along, and still checks
    ///      which slots are touched rather than counting SLOAD opcodes -- the optimizer can change
    ///      how many reads are emitted without changing the layout.
    function test_configOccupiesTwoSlots_exactInput() public {
        _assertConfigTouchesOnlyItsOwnSlots(-int256(STRADDLING_AMOUNT));
    }

    function test_configOccupiesTwoSlots_exactOutput() public {
        _assertConfigTouchesOnlyItsOwnSlots(int256(STRADDLING_AMOUNT));
    }

    function _assertConfigTouchesOnlyItsOwnSlots(int256 amountSpecified) internal {
        bytes32 configSlot = keccak256(abi.encode(id_, uint256(0)));

        bytes32 secondSlot = bytes32(uint256(configSlot) + 1);

        bytes32 spillSlot = bytes32(uint256(configSlot) + 2);

        vm.record();

        _swap(amountSpecified, true, _validHookData());

        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(hook));

        assertGt(_countMatches(reads, configSlot), 0, "the config slot was never read");

        assertGt(_countMatches(reads, secondSlot), 0, "the variable-leg minimums were never read");

        assertEq(_countMatches(reads, spillSlot), 0, "config spilled into a third slot (read)");

        assertEq(_countMatches(writes, spillSlot), 0, "config spilled into a third slot (write)");
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
        uint128 min0 = uint128(bound(uint256(raw0), 1, 1e9));

        uint96 min1 = uint96(bound(uint256(raw1), 1, 1e9));

        // Ranges narrowed to the band this pool's depth can actually execute -- see the note on
        // `THRESHOLD_1`. Above ~1e9 the swap exhausts the position and stops at its price limit,
        // which would make this a partial-fill test rather than a threshold-selection one.
        uint256 amount = bound(uint256(rawAmount), 1e6, 1e9);

        hook.setPoolConfig(key_, min0, min1, 10_000, 10_000, true);

        uint256 applicable = zeroForOne ? uint256(min0) : uint256(min1);

        // Supplying valid hookData is harmless on an unbonded exact-input swap
        // because the hook does not decode it unless the threshold is reached.
        uint256 bond = _bondTakenBy(-int256(amount), zeroForOne, _validHookData());

        if (amount < applicable) {
            // BELOW the threshold the claim is unconditional: eligibility is decided on the input
            // amount alone, and no impact, however large, can bond a trade that does not qualify.
            assertEq(bond, 0, "swap below its own currency's threshold was bonded");
        } else {
            // AT OR ABOVE the threshold the trade participates, but Model L still decides what it
            // pays -- and a swap that moved no whole tick pays nothing. That is not a threshold
            // failure, so the two outcomes are asserted separately rather than collapsed into one
            // expectation.
            uint256 expected = ModelLReference.collateralFor(_lastLeg, _lastTickBefore, _lastTickAfter);

            assertEq(bond, expected, "eligible swap did not take the Model L collateral");
        }
    }
}
