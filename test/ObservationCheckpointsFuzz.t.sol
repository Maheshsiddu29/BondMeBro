// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";
import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";

/// @title ObservationCheckpointsFuzzTest
///
/// @notice Randomized timelines against an independent block-by-block cumulative reference.
///
/// @dev WHAT THE UNIT SUITE CANNOT DO. `ObservationCheckpoints.t.sol` pins specific constructions —
///      a cursor at `open+7`, ten consecutive maturities, a fully quiet pool. Each is a point the
///      author thought of. This file generates timelines nobody chose: random gaps, random swap
///      kinds and directions, random quiet periods, overlapping maturities and same-block fan-in,
///      and checks the same properties wherever they land.
///
///      THE STRONG PROPERTY, and the reason this file exists rather than more unit tests:
///
///          after ONE swap beyond every outstanding maturity,
///          every due endpoint of every registered bucket is frozen AND exact.
///
///      "One swap" is what makes it strong. A scheduler that needed two advancements to catch up
///      would satisfy every eventual-consistency check and still strand an endpoint whenever the
///      pool went quiet at the wrong moment — and an endpoint stranded past `lastUpdate` is
///      unrecoverable, so the bond becomes unsettleable.
contract ObservationCheckpointsFuzzTest is Test, Deployers {
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

    /// @dev The same independent reference as the unit suite: integrates the POOL's tick, never the
    ///      hook's accumulator. See that file's header for why this is not circular.
    struct RefPoint {
        uint32 blockNumber;
        int56 cumulative;
        int24 tickFrom;
    }

    RefPoint[] internal refPoints;

    /// @dev Every block at which this run opened at least one bond.
    uint32[] internal openedAt;

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

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, true);

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

    function _swapTracked(int256 amountSpecified, bool zeroForOne, bytes memory hookData) internal returns (bool ok) {
        try swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        ) {
            ok = true;
        } catch {
            return false;
        }

        RefPoint memory last = refPoints[refPoints.length - 1];

        uint32 nowBlock = uint32(block.number);

        int56 cumulative = last.cumulative + int56(last.tickFrom) * int56(uint56(nowBlock - last.blockNumber));

        refPoints.push(RefPoint({blockNumber: nowBlock, cumulative: cumulative, tickFrom: _poolTick()}));
    }

    function _refCumulativeAt(uint32 atBlock) internal view returns (int56) {
        for (uint256 i = refPoints.length; i > 0; i--) {
            RefPoint memory p = refPoints[i - 1];

            if (p.blockNumber <= atBlock) {
                return p.cumulative + int56(p.tickFrom) * int56(uint56(atBlock - p.blockNumber));
            }
        }

        revert("reference does not cover a block before initialization");
    }

    function _lastUpdate() internal view returns (uint32 lastUpdate) {
        // slither-disable-next-line unused-return
        (, lastUpdate,,) = hook.accumulator(id_);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice One later swap past every outstanding maturity freezes every due endpoint, exactly.
    ///
    /// @dev The timeline is driven by a hash chain rather than by many fuzz parameters, so a single
    ///      seed reproduces a whole multi-step history and a shrunk counterexample stays runnable.
    ///
    ///      Four actions are drawn: a bonded exact-input swap, a bonded exact-output swap (which
    ///      exercises ADR-0004's split-phase lifecycle on the same scheduler), an unbonded swap
    ///      that advances the cursor without registering anything, and pure silence. Gaps of 0-12
    ///      blocks mean maturities routinely overlap and same-block fan-in happens naturally.
    function testFuzz_oneFlushFreezesEveryDueEndpointExactly(uint256 seed) public {
        uint256 rng = uint256(keccak256(abi.encode(seed)));

        uint32 firstBlock = uint32(block.number);

        for (uint256 step = 0; step < 12; step++) {
            rng = uint256(keccak256(abi.encode(rng)));

            uint32 gap = uint32(rng % 13);

            if (gap > 0) vm.roll(block.number + gap);

            uint256 action = (rng >> 32) % 4;
            bool zeroForOne = ((rng >> 64) & 1) == 1;

            if (action == 0) {
                if (_swapTracked(-1e16, zeroForOne, _hookData())) openedAt.push(uint32(block.number));
            } else if (action == 1) {
                if (_swapTracked(int256(1e16), zeroForOne, _hookData())) openedAt.push(uint32(block.number));
            } else if (action == 2) {
                _swapTracked(-1e13, zeroForOne, "");
            }
            // action == 3: pure silence.
        }

        // Move well past every outstanding maturity, then flush with EXACTLY ONE swap.
        vm.roll(uint256(firstBlock) + 12 * 13 + hook.OBSERVATION_BLOCKS() + 5);

        assertTrue(_swapTracked(-1e13, true, ""), "the flush swap failed");

        uint32 cursor = _lastUpdate();
        uint32 obs = hook.OBSERVATION_BLOCKS();

        uint256 checked;

        for (uint256 i = 0; i < openedAt.length; i++) {
            uint32 open = openedAt[i];
            uint32 m = open + obs;

            (int56 c6, int56 c8, int56 c10, uint32 pending, uint8 mask) = hook.maturity(id_, m);

            // A draw can be unbonded for reasons that have nothing to do with checkpoints -- a
            // sub-tick price move prices at zero bps under Model L and registers no bucket
            // (ADR-0007 s7). Nothing is owed for those.
            if (pending == 0) continue;

            checked++;

            // NO-MISSED-C6 / C8 / C10, each conditional on its own endpoint having been passed.
            if (open + 6 <= cursor) {
                assertTrue(mask & hook.FROZEN_C6() != 0, "NO-MISSED-C6: a due C6 was not frozen");

                assertEq(c6, _refCumulativeAt(open + 6), "frozen C6 does not match the independent reference");
            }

            if (open + 8 <= cursor) {
                assertTrue(mask & hook.FROZEN_C8() != 0, "NO-MISSED-C8: a due C8 was not frozen");

                assertEq(c8, _refCumulativeAt(open + 8), "frozen C8 does not match the independent reference");
            }

            if (m <= cursor) {
                assertTrue(mask & hook.FROZEN_C10() != 0, "NO-MISSED-C10: a due C10 was not frozen");

                assertEq(c10, _refCumulativeAt(m), "frozen C10 does not match the independent reference");
            }
        }

        // NON-VACUITY. A run that registered nothing would satisfy every assertion above by
        // skipping the loop body, so the campaign must be shown to have done real work.
        if (openedAt.length > 0) {
            assertGt(checked, 0, "every opened bond was unbonded; this run proved nothing");
        }
    }

    /// @notice No occupied bucket is ever left unfrozen outside the bounded scan horizon.
    ///
    /// @dev BOUNDED, from ADR-0007 § 6, and it is what keeps the loop bound honest. The scheduler
    ///      only scans `(lastUpdate, lastUpdate + OBSERVATION_BLOCKS]`. If an occupied, unfrozen
    ///      bucket could sit outside that window, the loop would have to grow to reach it — and
    ///      until it did, the endpoint would be silently stranded.
    ///
    ///      Swept across a wide band on both sides of the horizon, because a violation ABOVE the
    ///      horizon is exactly what a horizon-width sweep would miss.
    function testFuzz_noOccupiedUnfrozenBucketOutsideTheHorizon(uint256 seed) public {
        uint256 rng = uint256(keccak256(abi.encode(seed)));

        for (uint256 step = 0; step < 10; step++) {
            rng = uint256(keccak256(abi.encode(rng)));

            if (rng % 5 != 0) vm.roll(block.number + 1 + (rng % 7));

            if ((rng >> 8) % 3 == 0) {
                _swapTracked(-1e16, ((rng >> 16) & 1) == 1, _hookData());
            } else {
                _swapTracked(-1e13, ((rng >> 16) & 1) == 1, "");
            }

            uint32 cursor = _lastUpdate();
            uint32 horizon = cursor + hook.OBSERVATION_BLOCKS();

            // Anything occupied and unfrozen must lie inside (cursor, horizon].
            for (uint32 m = cursor > 40 ? cursor - 40 : 0; m <= horizon + 40; m++) {
                (,,, uint32 pending, uint8 mask) = hook.maturity(id_, m);

                if (pending == 0) continue;

                if (mask == hook.FROZEN_ALL()) continue;

                assertLe(m, horizon, "BOUNDED: an occupied, partly unfrozen bucket sits ABOVE the scan horizon");
            }
        }
    }

    /// @notice Frozen endpoints never change, however long and randomly the pool is hammered.
    ///
    /// @dev IMMUTABLE, over timelines nobody designed. The unit suite hammers one bucket; this
    ///      snapshots whatever the campaign froze and re-checks it after arbitrary further
    ///      activity, so a re-freeze triggered by an unusual cursor position has somewhere to show.
    function testFuzz_frozenEndpointsNeverChange(uint256 seed) public {
        uint256 rng = uint256(keccak256(abi.encode(seed)));

        for (uint256 step = 0; step < 8; step++) {
            rng = uint256(keccak256(abi.encode(rng)));

            vm.roll(block.number + 1 + (rng % 6));

            if (_swapTracked(-1e16, ((rng >> 16) & 1) == 1, _hookData())) openedAt.push(uint32(block.number));
        }

        vm.roll(block.number + hook.OBSERVATION_BLOCKS() + 3);

        _swapTracked(-1e13, true, "");

        // Snapshot everything currently frozen.
        uint32 obs = hook.OBSERVATION_BLOCKS();

        int56[] memory c6s = new int56[](openedAt.length);
        int56[] memory c8s = new int56[](openedAt.length);
        int56[] memory c10s = new int56[](openedAt.length);
        uint8[] memory masks = new uint8[](openedAt.length);

        for (uint256 i = 0; i < openedAt.length; i++) {
            (c6s[i], c8s[i], c10s[i],, masks[i]) = hook.maturity(id_, openedAt[i] + obs);
        }

        // Then hammer the pool hard, in both directions, far into the future.
        for (uint256 j = 0; j < 5; j++) {
            rng = uint256(keccak256(abi.encode(rng)));

            vm.roll(block.number + 1 + (rng % 40));

            _swapTracked(-1e16, (j % 2) == 0, _hookData());
        }

        vm.roll(block.number + 25_000);

        _swapTracked(-1e13, true, "");

        for (uint256 i = 0; i < openedAt.length; i++) {
            (int56 c6, int56 c8, int56 c10,, uint8 mask) = hook.maturity(id_, openedAt[i] + obs);

            // A set bit is never cleared; new bits may appear.
            assertEq(mask & masks[i], masks[i], "IMMUTABLE: a frozen mask bit was cleared");

            if (masks[i] & hook.FROZEN_C6() != 0) assertEq(c6, c6s[i], "IMMUTABLE: C6 changed after freezing");
            if (masks[i] & hook.FROZEN_C8() != 0) assertEq(c8, c8s[i], "IMMUTABLE: C8 changed after freezing");
            if (masks[i] & hook.FROZEN_C10() != 0) assertEq(c10, c10s[i], "IMMUTABLE: C10 changed after freezing");
        }
    }

    /// @notice Quiet derivation matches what a crossing swap would have frozen, for any quiet gap.
    ///
    /// @dev QUIET, fuzzed over the settlement delay. The claim is not merely that a quiet pool can
    ///      settle — it is that deriving gives the IDENTICAL value a swap would have frozen, which
    ///      is what makes the quiet path safe rather than an approximation. Both branches are run
    ///      on the same timeline from a shared snapshot and compared.
    function testFuzz_quietDerivationEqualsWhatACrossingSwapWouldFreeze(uint256 seed) public {
        uint32 open = uint32(block.number);
        uint32 m = open + hook.OBSERVATION_BLOCKS();

        assertTrue(_swapTracked(-1e16, true, _hookData()), "fixture swap failed");

        (,,, uint32 pending,) = hook.maturity(id_, m);

        vm.assume(pending == 1);

        uint32 delay = uint32(bound(uint256(keccak256(abi.encode(seed))), 0, 5_000));

        uint256 snapshot = vm.snapshotState();

        // BRANCH A -- a swap crosses every endpoint and freezes them.
        vm.roll(uint256(m) + delay);

        _swapTracked(-1e13, true, "");

        (int56 frozenC6, int56 frozenC8, int56 frozenC10,, uint8 mask) = hook.maturity(id_, m);

        assertEq(mask, hook.FROZEN_ALL(), "branch A did not freeze everything");

        vm.revertToState(snapshot);

        // BRANCH B -- nothing swaps at all; settlement derives instead.
        vm.roll(uint256(m) + delay);

        (int56 derivedC6, int56 derivedC8, int56 derivedC10) = hook.resolveEndpoints(bytes32(0), id_, m);

        assertEq(derivedC6, frozenC6, "QUIET: derived C6 differs from what a crossing swap froze");
        assertEq(derivedC8, frozenC8, "QUIET: derived C8 differs from what a crossing swap froze");
        assertEq(derivedC10, frozenC10, "QUIET: derived C10 differs from what a crossing swap froze");

        // And both equal the independent reference.
        assertEq(derivedC6, _refCumulativeAt(open + 6), "derived C6 does not match the reference");
        assertEq(derivedC8, _refCumulativeAt(open + 8), "derived C8 does not match the reference");
        assertEq(derivedC10, _refCumulativeAt(m), "derived C10 does not match the reference");
    }
}
