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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";
import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";

/// @title ObservationCheckpointsTest
///
/// @notice ADR-0007's three-endpoint checkpoint scheduler, proven against an INDEPENDENT reference.
///
/// @dev WHY AN INDEPENDENT REFERENCE, AND WHAT MAKES THIS ONE INDEPENDENT.
///
///      ADR-0007 § 6 is explicit: *"These must be checked against an independent reference, never
///      against the hook's own accumulator — that would be circular."* A test asserting
///      `frozenC6 == hook.accumulator(...).cumulativeAt(open+6)` proves only that the hook agrees
///      with itself, and would pass unchanged if every endpoint were off by a block.
///
///      The reference below integrates the POOL's tick, read from `PoolManager.getSlot0`, block by
///      block. It never reads the hook's accumulator. It is legitimate because the pool tick can
///      only change in a swap, and every swap runs `afterSwap`, so between swaps the tick is
///      constant and the integral is exact:
///
///          refCumulative(b + 1) = refCumulative(b) + tickEffectiveDuring[b, b+1)
///
///      matching `TickAccumulatorLib.update`, which credits `elapsed * lastTick` and seeds
///      `tickCumulative = 0` at the initialize block.
///
///      Every swap in this file therefore goes through `_swapTracked`, which records a reference
///      point immediately afterwards. A swap that bypassed it would silently desynchronise the
///      reference, so there are no raw `swapRouter.swap` calls here.
contract ObservationCheckpointsTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    BondMeBro internal hook;

    PoolKey internal key_;
    PoolId internal id_;

    address internal constant TRADER = address(0xB0B);

    uint128 internal constant MIN_BONDED = 1e15;
    uint96 internal constant MIN_BONDED_1 = 1e15;
    uint16 internal constant BOND_BPS = 25;
    uint16 internal constant REFUND_TOL = 5;

    uint128 internal constant GENEROUS_CEILING = type(uint128).max;

    int128 internal constant POOL_LIQUIDITY = 1e19;

    /// @dev Bonded: clears `MIN_BONDED` and moves the tick, so Model L actually prices it.
    int256 internal constant BONDED = -1e16;

    /// @dev Unbonded: below the threshold, so it advances the cursor and creates no bucket.
    int256 internal constant NUDGE = -1e13;

    /*//////////////////////////////////////////////////////////////
                        THE INDEPENDENT REFERENCE
    //////////////////////////////////////////////////////////////*/

    /// @dev One observation of the pool: from `blockNumber` onward the tick is `tickFrom`, and the
    ///      integral up to `blockNumber` is `cumulative`.
    struct RefPoint {
        uint32 blockNumber;
        int56 cumulative;
        int24 tickFrom;
    }

    RefPoint[] internal refPoints;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(this)));

        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), address(this));

        assertEq(address(hook), predicted, "mined address mismatch");

        (key_, id_) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, TickMath.getSqrtPriceAtTick(0));

        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: POOL_LIQUIDITY, salt: bytes32(uint256(1))
            }),
            ""
        );

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, 10_000, 10_000, true);

        // Seed the reference where the hook seeded its accumulator: at initialization, with a
        // cumulative of zero.
        refPoints.push(RefPoint({blockNumber: uint32(block.number), cumulative: 0, tickFrom: _poolTick()}));
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _poolTick() internal view returns (int24 tick) {
        // slither-disable-next-line unused-return
        (, tick,,) = manager.getSlot0(id_);
    }

    function _hookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, GENEROUS_CEILING);
    }

    /// @dev Swaps, then extends the independent reference to this block.
    function _swapTracked(int256 amountSpecified, bool zeroForOne, bytes memory hookData) internal {
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

        RefPoint memory last = refPoints[refPoints.length - 1];

        uint32 nowBlock = uint32(block.number);

        int56 cumulative = last.cumulative + int56(last.tickFrom) * int56(uint56(nowBlock - last.blockNumber));

        refPoints.push(RefPoint({blockNumber: nowBlock, cumulative: cumulative, tickFrom: _poolTick()}));
    }

    /// @dev Opens one bonded swap and returns its opening block and maturity.
    function _openBond() internal returns (uint32 openBlock, uint32 maturityBlock) {
        openBlock = uint32(block.number);
        maturityBlock = openBlock + hook.OBSERVATION_BLOCKS();

        _swapTracked(BONDED, true, _hookData());
    }

    /// @dev Advances to `target` and runs one unbonded swap there, so the scheduler runs.
    function _nudgeAt(uint32 target) internal {
        vm.roll(target);

        _swapTracked(NUDGE, true, "");
    }

    /// @dev The independent cumulative at an arbitrary block.
    function _refCumulativeAt(uint32 atBlock) internal view returns (int56) {
        for (uint256 i = refPoints.length; i > 0; i--) {
            RefPoint memory p = refPoints[i - 1];

            if (p.blockNumber <= atBlock) {
                return p.cumulative + int56(p.tickFrom) * int56(uint56(atBlock - p.blockNumber));
            }
        }

        revert("reference does not cover a block before initialization");
    }

    function _bucket(uint32 m) internal view returns (int56 c6, int56 c8, int56 c10, uint32 pending, uint8 mask) {
        return hook.maturity(id_, m);
    }

    function _mask(uint32 m) internal view returns (uint8 mask) {
        (,,,, mask) = hook.maturity(id_, m);
    }

    function _lastUpdate() internal view returns (uint32 lastUpdate) {
        // slither-disable-next-line unused-return
        (, lastUpdate,,) = hook.accumulator(id_);
    }

    /// @dev Asserts every frozen endpoint of a bucket equals the independent reference.
    function _assertFrozenEndpointsExact(uint32 m, string memory label) internal view {
        (int56 c6, int56 c8, int56 c10,, uint8 mask) = _bucket(m);

        if (mask & hook.FROZEN_C6() != 0) {
            assertEq(
                c6,
                _refCumulativeAt(m - hook.C6_OFFSET_FROM_MATURITY()),
                string.concat(label, ": frozen C6 does not match the independent reference")
            );
        }

        if (mask & hook.FROZEN_C8() != 0) {
            assertEq(
                c8,
                _refCumulativeAt(m - hook.C8_OFFSET_FROM_MATURITY()),
                string.concat(label, ": frozen C8 does not match the independent reference")
            );
        }

        if (mask & hook.FROZEN_C10() != 0) {
            assertEq(c10, _refCumulativeAt(m), string.concat(label, ": frozen C10 does not match the reference"));
        }
    }

    /*//////////////////////////////////////////////////////////////
                    1-4  EACH ENDPOINT FREEZES EXACTLY
    //////////////////////////////////////////////////////////////*/

    /// @notice C6 freezes at `M - 4`, with the exact independent cumulative, and alone.
    ///
    /// @dev "Alone" is the load-bearing half. A scheduler that froze all three whenever any one
    ///      became due would satisfy an exactness check but destroy the property the mask exists
    ///      for — C8 and C10 have not happened yet, and freezing them now would capture the wrong
    ///      value and make it immutable.
    function test_c6_freezesExactlyAndAlone() public {
        (uint32 open, uint32 m) = _openBond();

        _nudgeAt(open + 6);

        (int56 c6,,,, uint8 mask) = _bucket(m);

        assertEq(mask, hook.FROZEN_C6(), "only C6 should be frozen at open+6");

        assertEq(c6, _refCumulativeAt(open + 6), "C6 does not equal the independent cumulative at open+6");

        assertEq(c6, _refCumulativeAt(m - 4), "C6 is not the endpoint at M-4");
    }

    /// @notice C8 freezes at `M - 2` with the exact value; C10 stays unfrozen.
    ///
    /// @dev Advancing straight to `open+8` crosses C6 as well, so both freeze in this one
    ///      advancement and the assertion is on the pair — which is itself the interesting
    ///      property, since they must take DIFFERENT values from the same snapshot.
    function test_c8_freezesExactly_c10StillOpen() public {
        (uint32 open, uint32 m) = _openBond();

        _nudgeAt(open + 8);

        (int56 c6, int56 c8,,, uint8 mask) = _bucket(m);

        assertEq(mask, hook.FROZEN_C6() | hook.FROZEN_C8(), "C6 and C8 should be frozen, C10 not");

        assertEq(c6, _refCumulativeAt(open + 6), "C6 wrong");
        assertEq(c8, _refCumulativeAt(open + 8), "C8 does not equal the independent cumulative at open+8");

        assertEq(c8, _refCumulativeAt(m - 2), "C8 is not the endpoint at M-2");
    }

    /// @notice C10 freezes at `M` with the exact value.
    function test_c10_freezesExactly() public {
        (uint32 open, uint32 m) = _openBond();

        _nudgeAt(open + 6);
        _nudgeAt(open + 8);
        _nudgeAt(m);

        (,, int56 c10,, uint8 mask) = _bucket(m);

        assertEq(mask, hook.FROZEN_ALL(), "all three endpoints should be frozen by M");

        assertEq(c10, _refCumulativeAt(m), "C10 does not equal the independent cumulative at M");

        _assertFrozenEndpointsExact(m, "c10 walk");
    }

    /// @notice A single advancement crossing all three endpoints freezes all three, each exact.
    ///
    /// @dev The case a per-block scheduler would have had to visit three times. One swap at `M`
    ///      after silence since `open` must capture three DIFFERENT values from one snapshot.
    function test_allThreeFreezeInOneAdvancement() public {
        (uint32 open, uint32 m) = _openBond();

        _nudgeAt(m);

        (int56 c6, int56 c8, int56 c10,, uint8 mask) = _bucket(m);

        assertEq(mask, hook.FROZEN_ALL(), "one advancement past M must freeze all three");

        assertEq(c6, _refCumulativeAt(open + 6), "C6 wrong in a single advancement");
        assertEq(c8, _refCumulativeAt(open + 8), "C8 wrong in a single advancement");
        assertEq(c10, _refCumulativeAt(m), "C10 wrong in a single advancement");

        // They must be genuinely distinct, or the test would pass on a scheduler that wrote the
        // same value into all three fields.
        assertTrue(c6 != c8 || c8 != c10, "all three endpoints are identical; the fixture proves nothing");
    }

    /*//////////////////////////////////////////////////////////////
                  5  BLOCK-BY-BLOCK ADVANCEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Walking one block at a time freezes each endpoint at exactly its own block.
    ///
    /// @dev The strongest ordering check available: at every block the mask must be exactly what
    ///      the endpoint definitions imply, so an endpoint that froze one block early or late
    ///      fails at the block it happened rather than at the end.
    function test_blockByBlock_eachEndpointFreezesAtItsOwnBlock() public {
        (uint32 open, uint32 m) = _openBond();

        for (uint32 b = open + 1; b <= m + 2; b++) {
            _nudgeAt(b);

            uint8 expected;

            if (b >= open + 6) expected |= hook.FROZEN_C6();
            if (b >= open + 8) expected |= hook.FROZEN_C8();
            if (b >= m) expected |= hook.FROZEN_C10();

            assertEq(_mask(m), expected, string.concat("mask wrong at block offset ", vm.toString(uint256(b - open))));

            _assertFrozenEndpointsExact(m, string.concat("block ", vm.toString(uint256(b))));
        }
    }

    /*//////////////////////////////////////////////////////////////
              6-10  QUIET DERIVATION AND CURSOR POSITIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice A completely quiet pool derives all three endpoints exactly at settlement time.
    ///
    /// @dev The quiet-pool rule is unchanged by ADR-0007 and is what lets a bond settle with no
    ///      keeper: nothing swapped after `open`, so the tick never changed and every endpoint is
    ///      still exactly reconstructible from unchanged state.
    ///
    ///      Crucially this must NOT auto-refund. Deriving is not the same as forgiving: the value
    ///      derived is precisely the one a crossing swap would have frozen.
    function test_quiet_allThreeDerivedExactly() public {
        (uint32 open, uint32 m) = _openBond();

        // Total silence from `open` to well past `M`.
        vm.roll(uint256(m) + 50);

        assertEq(_lastUpdate(), open, "fixture: the pool must be silent since open");

        assertEq(_mask(m), 0, "nothing should be frozen on a silent pool");

        (int56 c6, int56 c8, int56 c10) = hook.resolveEndpoints(bytes32(0), id_, m);

        assertEq(c6, _refCumulativeAt(open + 6), "quiet C6 derivation is wrong");
        assertEq(c8, _refCumulativeAt(open + 8), "quiet C8 derivation is wrong");
        assertEq(c10, _refCumulativeAt(m), "quiet C10 derivation is wrong");

        // Resolution freezes what it derived, so the values are now permanent.
        assertEq(_mask(m), hook.FROZEN_ALL(), "resolution did not freeze what it derived");

        _assertFrozenEndpointsExact(m, "quiet");
    }

    /// @notice Cursor between C6 and C8: C6 frozen, the other two still exactly derivable.
    ///
    /// @dev THE CASE THE SINGLE BOOLEAN COULD NOT EXPRESS, and the reason `frozenMask` has three
    ///      bits. At `lastUpdate == open+7` the bucket is genuinely half-resolved: one endpoint is
    ///      history and two are still in the accumulator's reach. A per-bond flag would have had
    ///      to answer "is this checkpointed?" with a single yes or no.
    function test_cursorBetweenC6AndC8_resolvesEachIndependently() public {
        (uint32 open, uint32 m) = _openBond();

        _nudgeAt(open + 7);

        assertEq(_mask(m), hook.FROZEN_C6(), "only C6 should be frozen with the cursor at open+7");

        assertEq(_lastUpdate(), open + 7, "fixture: cursor must sit between C6 and C8");

        vm.roll(uint256(m) + 20);

        (int56 c6, int56 c8, int56 c10) = hook.resolveEndpoints(bytes32(0), id_, m);

        assertEq(c6, _refCumulativeAt(open + 6), "stored C6 wrong");
        assertEq(c8, _refCumulativeAt(open + 8), "derived C8 wrong");
        assertEq(c10, _refCumulativeAt(m), "derived C10 wrong");
    }

    /// @notice Cursor between C8 and C10: two frozen, C10 still derivable.
    function test_cursorBetweenC8AndC10_resolvesEachIndependently() public {
        (uint32 open, uint32 m) = _openBond();

        _nudgeAt(open + 9);

        assertEq(_mask(m), hook.FROZEN_C6() | hook.FROZEN_C8(), "C6 and C8 should be frozen at open+9");

        vm.roll(uint256(m) + 1_000);

        (int56 c6, int56 c8, int56 c10) = hook.resolveEndpoints(bytes32(0), id_, m);

        assertEq(c6, _refCumulativeAt(open + 6), "stored C6 wrong");
        assertEq(c8, _refCumulativeAt(open + 8), "stored C8 wrong");
        assertEq(c10, _refCumulativeAt(m), "derived C10 wrong");
    }

    /// @notice A swap immediately before each endpoint leaves that endpoint still open.
    ///
    /// @dev The off-by-one guard. Freezing is inclusive of the endpoint block and exclusive below
    ///      it, so activity at `e - 1` must NOT freeze `e`.
    function test_activityImmediatelyBeforeAnEndpointDoesNotFreezeIt() public {
        (uint32 open, uint32 m) = _openBond();

        _nudgeAt(open + 5);
        assertEq(_mask(m), 0, "C6 froze one block early");

        _nudgeAt(open + 6);
        assertEq(_mask(m), hook.FROZEN_C6(), "C6 did not freeze at its own block");

        _nudgeAt(open + 7);
        assertEq(_mask(m), hook.FROZEN_C6(), "C8 froze one block early");

        _nudgeAt(open + 8);
        assertEq(_mask(m), hook.FROZEN_C6() | hook.FROZEN_C8(), "C8 did not freeze at its own block");

        _nudgeAt(m - 1);
        assertEq(_mask(m), hook.FROZEN_C6() | hook.FROZEN_C8(), "C10 froze one block early");

        _nudgeAt(m);
        assertEq(_mask(m), hook.FROZEN_ALL(), "C10 did not freeze at M");
    }

    /*//////////////////////////////////////////////////////////////
                        11-13  IMMUTABILITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Once frozen, no endpoint value ever changes and no mask bit is ever cleared.
    ///
    /// @dev Hammered with real swaps that move the price substantially, because the failure mode
    ///      is a re-freeze picking up the NEW tick — which only shows if the tick actually moved.
    ///      Checked per endpoint, so a scheduler that kept C10 stable while rewriting C6 fails.
    function test_frozenEndpointsAreImmutable() public {
        (uint32 open, uint32 m) = _openBond();

        _nudgeAt(m);

        (int56 c6, int56 c8, int56 c10,, uint8 mask) = _bucket(m);

        assertEq(mask, hook.FROZEN_ALL(), "fixture did not freeze everything");

        // Hammer the pool hard, in both directions, well past maturity.
        for (uint256 i = 0; i < 6; i++) {
            vm.roll(block.number + 3);

            _swapTracked(BONDED, i % 2 == 0, _hookData());
        }

        vm.roll(block.number + 5_000);

        _swapTracked(NUDGE, true, "");

        (int56 c6After, int56 c8After, int56 c10After,, uint8 maskAfter) = _bucket(m);

        assertEq(c6After, c6, "C6 changed after freezing");
        assertEq(c8After, c8, "C8 changed after freezing");
        assertEq(c10After, c10, "C10 changed after freezing");
        assertEq(maskAfter, mask, "the frozen mask changed after freezing");

        // Still exact against the reference, which by now has moved a long way.
        assertEq(c6, _refCumulativeAt(open + 6), "C6 no longer matches the reference");
        assertEq(c8, _refCumulativeAt(open + 8), "C8 no longer matches the reference");
        assertEq(c10, _refCumulativeAt(m), "C10 no longer matches the reference");
    }

    /*//////////////////////////////////////////////////////////////
                  14-15  FAN-IN AND CONSECUTIVE MATURITIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Many bonds in one block share one bucket, one set of endpoints, one freeze each.
    ///
    /// @dev The claim ADR-0007 § 3.1 makes: maturity is `open + 10`, an injective map, so a
    ///      thousand bonds opened in the same block still need one bucket. `pendingBonds` counts
    ///      them all; the endpoints are properties of the POOL and are stored once.
    function test_manyBondsOneMaturity_shareOneBucketAndOneFreeze() public {
        uint32 open = uint32(block.number);
        uint32 m = open + hook.OBSERVATION_BLOCKS();

        for (uint256 i = 0; i < 8; i++) {
            _swapTracked(BONDED, true, _hookData());
        }

        (,,, uint32 pending,) = _bucket(m);

        assertEq(pending, 8, "eight bonds did not land in one bucket");

        _nudgeAt(m);

        (int56 c6, int56 c8, int56 c10,, uint8 mask) = _bucket(m);

        assertEq(mask, hook.FROZEN_ALL(), "the shared bucket did not freeze");

        assertEq(c6, _refCumulativeAt(open + 6), "shared C6 wrong");
        assertEq(c8, _refCumulativeAt(open + 8), "shared C8 wrong");
        assertEq(c10, _refCumulativeAt(m), "shared C10 wrong");
    }

    /// @notice Ten consecutive opening blocks give ten distinct buckets, each exact.
    ///
    /// @dev The maximum number of occupied buckets one advancement can be responsible for, and the
    ///      arrangement the scan bound is sized against. Every bucket's three endpoints must be
    ///      right — thirty values from one scheduler.
    function test_consecutiveMaturities_eachBucketExact() public {
        uint32 firstOpen = uint32(block.number);

        for (uint32 i = 0; i < hook.OBSERVATION_BLOCKS(); i++) {
            _swapTracked(BONDED, true, _hookData());

            vm.roll(block.number + 1);
        }

        // One flush past every outstanding maturity.
        vm.roll(uint256(firstOpen) + hook.OBSERVATION_BLOCKS() + 40);

        _swapTracked(NUDGE, true, "");

        for (uint32 i = 0; i < hook.OBSERVATION_BLOCKS(); i++) {
            uint32 open = firstOpen + i;
            uint32 m = open + hook.OBSERVATION_BLOCKS();

            (int56 c6, int56 c8, int56 c10, uint32 pending, uint8 mask) = _bucket(m);

            assertEq(pending, 1, "a consecutive bucket lost its bond");

            assertEq(mask, hook.FROZEN_ALL(), "a consecutive bucket did not fully freeze");

            assertEq(c6, _refCumulativeAt(open + 6), "consecutive C6 wrong");
            assertEq(c8, _refCumulativeAt(open + 8), "consecutive C8 wrong");
            assertEq(c10, _refCumulativeAt(m), "consecutive C10 wrong");
        }
    }

    /*//////////////////////////////////////////////////////////////
          16-18  PHANTOM BUCKETS, CONTAMINATION, STALE REUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Scanning never creates a bucket. Unbonded activity leaves the whole horizon empty.
    ///
    /// @dev THE GUARANTEE THAT MAKES FORWARD WRITES SAFE. The scheduler writes into buckets AHEAD
    ///      of the cursor, up to four blocks past `nowBlock`. Without the `pendingBonds == 0`
    ///      early return, a scan could conjure a maturity cohort for a bond that never existed —
    ///      and `pendingBonds` is the sole occupancy signal (ADR-0004 Rule 3) that settlement,
    ///      registration and the invariants all key off.
    ///
    ///      The sweep is deliberately wider than the scan horizon, because a phantom written
    ///      outside it is exactly what a horizon-width check would miss.
    function test_noPhantomBucket_unbondedActivityCreatesNothing() public {
        uint32 start = uint32(block.number);

        for (uint32 i = 0; i < 30; i++) {
            _nudgeAt(start + i + 1);
        }

        for (uint32 b = start; b <= start + 60; b++) {
            (int56 c6, int56 c8, int56 c10, uint32 pending, uint8 mask) = _bucket(b);

            assertEq(pending, 0, "a phantom bucket acquired a pending bond");
            assertEq(mask, 0, "a phantom bucket acquired a frozen mask");
            assertEq(c6, int56(0), "a phantom bucket acquired a C6");
            assertEq(c8, int56(0), "a phantom bucket acquired a C8");
            assertEq(c10, int56(0), "a phantom bucket acquired a C10");
        }
    }

    /// @notice A bond opened later cannot inherit a checkpoint frozen before it existed.
    ///
    /// @dev ADR-0007 § 3.4's argument, tested rather than merely reasoned.
    ///
    ///      The lifecycle: bucket `M` needs a bond opened at `M - 10`, and that bond's earliest
    ///      endpoint is `M - 4` — six blocks AFTER it registers. So a bond is always registered
    ///      before any of its own endpoints can be scanned, and combined with the no-phantom
    ///      guarantee a forward write can only land on a cohort that already exists.
    ///
    ///      Constructed adversarially: run a long stretch of scanning activity with no bonds at
    ///      all, then open a bond whose bucket the scanner has repeatedly swept past, and check it
    ///      starts completely clean and then freezes its OWN values.
    function test_noFutureBondContamination() public {
        uint32 start = uint32(block.number);

        // Scan repeatedly over the region where a future bond's bucket will live.
        for (uint32 i = 0; i < 20; i++) {
            _nudgeAt(start + i + 1);
        }

        // Now open a bond. Its bucket has been swept many times already.
        (uint32 open, uint32 m) = _openBond();

        (int56 c6, int56 c8, int56 c10,, uint8 mask) = _bucket(m);

        assertEq(mask, 0, "a newly registered bucket inherited a frozen mask");
        assertEq(c6, int56(0), "a newly registered bucket inherited a C6");
        assertEq(c8, int56(0), "a newly registered bucket inherited a C8");
        assertEq(c10, int56(0), "a newly registered bucket inherited a C10");

        // And when it does freeze, it freezes its own values.
        _nudgeAt(m);

        (int56 c6b, int56 c8b, int56 c10b,, uint8 maskAfter) = _bucket(m);

        assertEq(maskAfter, hook.FROZEN_ALL(), "the late bond's bucket did not freeze");

        assertEq(c6b, _refCumulativeAt(open + 6), "late bond C6 is not its own");
        assertEq(c8b, _refCumulativeAt(open + 8), "late bond C8 is not its own");
        assertEq(c10b, _refCumulativeAt(m), "late bond C10 is not its own");
    }

    /// @notice A settled bucket's frozen data is never reused by a later bond at another maturity.
    ///
    /// @dev Buckets are keyed by maturity block and never deleted (ADR-0003 § 5.4), so "stale
    ///      reuse" would mean a NEW bond at a DIFFERENT maturity somehow reading the old bucket's
    ///      values. Checked by giving the two bonds genuinely different tick histories and
    ///      asserting the endpoint values differ.
    function test_noStaleReuse_acrossDistinctMaturities() public {
        (uint32 openA, uint32 mA) = _openBond();

        _nudgeAt(mA);

        (,, int56 c10A,,) = _bucket(mA);

        // Move the price a long way, so a stale read would be obvious.
        for (uint256 i = 0; i < 4; i++) {
            vm.roll(block.number + 2);

            _swapTracked(BONDED * 3, true, _hookData());
        }

        vm.roll(block.number + 30);

        (uint32 openB, uint32 mB) = _openBond();

        assertTrue(mB != mA, "fixture: the two bonds must have different maturities");

        _nudgeAt(mB);

        (int56 c6B, int56 c8B, int56 c10B,,) = _bucket(mB);

        assertEq(c6B, _refCumulativeAt(openB + 6), "second bond C6 is stale");
        assertEq(c8B, _refCumulativeAt(openB + 8), "second bond C8 is stale");
        assertEq(c10B, _refCumulativeAt(mB), "second bond C10 is stale");

        assertTrue(c10B != c10A, "the two maturities produced identical C10; the fixture proves nothing");

        // The first bucket is untouched by any of it.
        (,, int56 c10AAfter,,) = _bucket(mA);

        assertEq(c10AAfter, c10A, "the earlier bucket was overwritten");

        // The first bucket's own endpoints are still right too, which is what rules out a later
        // bond quietly rewriting an earlier cohort's history.
        assertEq(c10A, _refCumulativeAt(mA), "the earlier bucket no longer matches the reference");

        (int56 c6A,,,,) = _bucket(mA);

        assertEq(c6A, _refCumulativeAt(openA + 6), "the earlier bucket's C6 no longer matches the reference");
    }

    /*//////////////////////////////////////////////////////////////
              19-20  SETTLEMENT INTERACTION AND EQUIVALENCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Settling decrements `pendingBonds` and leaves every checkpoint field untouched.
    ///
    /// @dev `pendingBonds` shares one word with all three endpoints and the mask, so a decrement
    ///      with a wrong shift would corrupt a neighbouring endpoint and every balance assertion
    ///      would still pass. Driven with several bonds in one bucket so the counter moves more
    ///      than once.
    function test_settlementDecrement_preservesEveryCheckpointField() public {
        uint32 open = uint32(block.number);
        uint32 m = open + hook.OBSERVATION_BLOCKS();

        bytes32[] memory ids = new bytes32[](3);

        for (uint32 i = 0; i < 3; i++) {
            ids[i] = keccak256(abi.encode(id_, m, i));

            _swapTracked(BONDED, true, _hookData());
        }

        _nudgeAt(m);

        (int56 c6, int56 c8, int56 c10, uint32 pending, uint8 mask) = _bucket(m);

        assertEq(pending, 3, "fixture did not register three bonds");
        assertEq(mask, hook.FROZEN_ALL(), "fixture did not freeze the bucket");

        for (uint32 i = 0; i < 3; i++) {
            hook.settleBond(ids[i]);

            (int56 c6b, int56 c8b, int56 c10b, uint32 pendingAfter, uint8 maskAfter) = _bucket(m);

            assertEq(pendingAfter, 3 - i - 1, "pendingBonds did not decrement by exactly one");

            assertEq(c6b, c6, "settlement disturbed C6");
            assertEq(c8b, c8, "settlement disturbed C8");
            assertEq(c10b, c10, "settlement disturbed C10");
            assertEq(maskAfter, mask, "settlement disturbed the frozen mask");
        }

        // Reaching zero must NOT delete the bucket: ADR-0003 § 5.4's no-deletion rule is unchanged,
        // and permissionless late settlement depends on the data still being there.
        (int56 c6z, int56 c8z, int56 c10z, uint32 zero, uint8 maskZ) = _bucket(m);

        assertEq(zero, 0, "the bucket should now be empty of liabilities");
        assertEq(maskZ, hook.FROZEN_ALL(), "checkpoint data was deleted when pendingBonds hit zero");
        assertEq(c6z, c6, "C6 was deleted at zero");
        assertEq(c8z, c8, "C8 was deleted at zero");
        assertEq(c10z, c10, "C10 was deleted at zero");
    }

    /// @notice Settlement is independent of WHEN it is called, across the new representation.
    ///
    /// @dev ADR-0003's governing invariant, which ADR-0007 explicitly does not supersede:
    ///      `settlement at M == settlement at M+1 == settlement at M+10,000`. Settlement is
    ///      permissionless, so if the answer moved with the calling block whoever picked the block
    ///      would be picking the answer.
    ///
    ///      Re-proven here because the READ path changed: settlement now takes C10 out of a
    ///      five-field packed bucket instead of a three-field one.
    function test_settlementIsIndependentOfCallTime() public {
        uint256 baseline = vm.snapshotState();

        uint128 atM = _settleAndMeasureRefundAt(0);

        vm.revertToState(baseline);

        uint128 atM1 = _settleAndMeasureRefundAt(1);

        vm.revertToState(baseline);

        uint128 atMFar = _settleAndMeasureRefundAt(10_000);

        assertEq(atM1, atM, "settling one block later changed the refund");
        assertEq(atMFar, atM, "settling 10,000 blocks later changed the refund");
    }

    /// @dev Opens a bond, lets it mature, settles `delay` blocks after M, returns the refund.
    function _settleAndMeasureRefundAt(uint32 delay) internal returns (uint128) {
        uint32 open = uint32(block.number);
        uint32 m = open + hook.OBSERVATION_BLOCKS();

        bytes32 bondId = keccak256(abi.encode(id_, m, uint32(0)));

        _swapTracked(BONDED, true, _hookData());

        _nudgeAt(m);

        if (delay > 0) vm.roll(uint256(m) + delay);

        Currency c = hook.getBond(bondId).collateralIsCurrency0 ? currency0 : currency1;

        uint256 before = c.balanceOf(TRADER);

        hook.settleBond(bondId);

        return uint128(c.balanceOf(TRADER) - before);
    }

    /*//////////////////////////////////////////////////////////////
              23-24  BOUNDARY REGISTRATION AND REVERTS
    //////////////////////////////////////////////////////////////*/

    /// @notice A bond registering in the same block a scan runs still gets a clean bucket.
    ///
    /// @dev The tightest ordering in the design: `beforeSwap` runs the scan and then the same swap
    ///      registers a bond in `afterSwap`. The scan sweeps buckets up to four blocks past the
    ///      current one, and the bond being created maturs ten blocks out — so the scan cannot
    ///      have touched it, but the two happen in one transaction and the ordering is worth
    ///      pinning.
    function test_registrationInTheSameBlockAsAScan_startsClean() public {
        // Get an earlier bond in flight so the scan has real work to do.
        (, uint32 mA) = _openBond();

        vm.roll(uint256(mA));

        // This swap's `beforeSwap` freezes bucket mA; its `afterSwap` registers a NEW bond.
        uint32 openB = uint32(block.number);
        uint32 mB = openB + hook.OBSERVATION_BLOCKS();

        _swapTracked(BONDED, true, _hookData());

        assertEq(_mask(mA), hook.FROZEN_ALL(), "the in-flight bucket did not freeze");

        (int56 c6, int56 c8, int56 c10, uint32 pending, uint8 mask) = _bucket(mB);

        assertEq(pending, 1, "the new bond did not register");
        assertEq(mask, 0, "the new bucket started with a frozen mask");
        assertEq(c6, int56(0), "the new bucket started with a C6");
        assertEq(c8, int56(0), "the new bucket started with a C8");
        assertEq(c10, int56(0), "the new bucket started with a C10");
    }

    /// @notice A reverted swap leaves no checkpoint state behind.
    ///
    /// @dev The scheduler runs in `beforeSwap`, so a revert raised later in `afterSwap` — by the
    ///      trader's ceiling, say — unwinds freezes that had already been written in the same
    ///      transaction. That is correct (the whole call reverts) but worth pinning, because a
    ///      freeze is the one thing in this design that writes state for a DIFFERENT bond than the
    ///      one being processed.
    function test_revertedSwap_rollsBackCheckpointState() public {
        (, uint32 m) = _openBond();

        vm.roll(uint256(m));

        uint8 maskBefore = _mask(m);

        assertEq(maskBefore, 0, "fixture: nothing should be frozen yet");

        // A ceiling of 1 is below any bond this pool can produce, so `afterSwap` reverts.
        vm.expectRevert();

        swapRouter.swap(
            key_,
            SwapParams({zeroForOne: true, amountSpecified: BONDED, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            HookDataCodec.encode(TRADER, 1)
        );

        assertEq(_mask(m), maskBefore, "a reverted swap left checkpoint state behind");

        (,,, uint32 pending,) = _bucket(m);

        assertEq(pending, 1, "a reverted swap changed the pending count");

        // And the endpoint still freezes correctly on the next successful swap.
        _swapTracked(NUDGE, true, "");

        assertEq(_mask(m), hook.FROZEN_ALL(), "the endpoint did not freeze after the failed attempt");
    }

    /*//////////////////////////////////////////////////////////////
                        UNRECOVERABLE ENDPOINTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Resolution names the EARLIEST unrecoverable endpoint, not a later one.
    ///
    /// @dev ADR-0007 § 3.5. Resolution order is C6, then C8, then C10, so an operator is pointed at
    ///      the value that is actually lost rather than at whichever one happened to be checked
    ///      first. Constructed by corrupting a fully frozen bucket back to unfrozen while the
    ///      cursor sits far past every endpoint — the state a missed NO-MISSED-Cx would leave.
    function test_resolution_namesTheEarliestUnrecoverableEndpoint() public {
        (, uint32 m) = _openBond();

        _nudgeAt(m);

        vm.roll(uint256(m) + 50);

        _swapTracked(NUDGE, true, "");

        (,,, uint32 pending,) = _bucket(m);

        // Clear every endpoint and the mask, keeping the liability. `pendingBonds` is at byte 21.
        bytes32 slot = keccak256(abi.encode(uint256(m), keccak256(abi.encode(id_, uint256(2)))));

        vm.store(address(hook), slot, bytes32(uint256(pending) << 168));

        assertEq(_mask(m), 0, "fixture: the bucket should now read unfrozen");

        uint32 lastUpdate = _lastUpdate();

        assertGt(lastUpdate, m, "fixture: the cursor must be past every endpoint");

        // C6 is the earliest lost endpoint, so it is the one named.
        vm.expectRevert(
            abi.encodeWithSelector(
                BondMeBro.MaturityCheckpointMissing.selector, bytes32(0), m - hook.C6_OFFSET_FROM_MATURITY(), lastUpdate
            )
        );

        hook.resolveEndpoints(bytes32(0), id_, m);
    }
}
