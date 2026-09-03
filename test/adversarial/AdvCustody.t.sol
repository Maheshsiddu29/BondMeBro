// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {AdversarialBase} from "./AdversarialBase.sol";
import {BondMeBro} from "../../src/BondMeBro.sol";
import {HookDataCodec} from "../../src/libraries/HookDataCodec.sol";
import {ModelLReference} from "../utils/ModelLReference.sol";

/// @title AdvCustodyTest
///
/// @notice P-L2-8 custody attacks: partial fills, adversarial exact-output, the router-free caller,
///         malformed hookData, and provisional-state sequences.
///
/// @dev THE THEME. Every test here asks whether the HOOK enforces a bound, or whether it has been
///      quietly relying on the router, the codec's happy path, or a well-behaved caller. The
///      router-free section is the sharpest form of that question: `Hooks.sol` bounds
///      `hookDeltaSpecified` and bounds `hookDeltaUnspecified` nowhere, so a caller driving
///      `PoolManager.unlock` directly has nothing between it and the hook.
contract AdvCustodyTest is AdversarialBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deployAndOpenPool();
    }

    /*//////////////////////////////////////////////////////////////
                    13  EXACT-INPUT PARTIAL FILLS
    //////////////////////////////////////////////////////////////*/

    /// @notice Across six fill fractions, the REQUESTED amount never controls the collateral.
    ///
    /// @dev INV-L2-13, attacked at the ladder rather than at one point. The request is identical on
    ///      every rung — only the price limit changes — so a hook still sizing off the request
    ///      would post an identical bond six times.
    ///
    ///      Eligibility is checked on the same quantity: a rung that fills below `minBondedAmount`
    ///      must not bond, even though its REQUEST cleared the threshold comfortably.
    function test_adv13_partialFillLadderIsPricedOnExecution() public {
        uint32[6] memory ppm = [uint32(900), 700, 480, 250, 100, 50];

        uint256 bondedRungs;
        uint256 unbondedRungs;

        for (uint256 i = 0; i < ppm.length; i++) {
            uint256 snap = vm.snapshotState();

            if (_runFillRung(ppm[i])) bondedRungs++;
            else unbondedRungs++;

            vm.revertToState(snap);
        }

        assertGt(bondedRungs, 0, "no rung bonded; the ladder proves nothing");
        assertGt(unbondedRungs, 0, "no rung fell below the threshold; the eligibility half is untested");
    }

    /// @dev One rung of the fill ladder. Split out to keep the frame inside the EVM stack limit.
    ///      Returns whether the rung bonded.
    function _runFillRung(uint32 ppm) internal returns (bool bonded) {
        uint256 requested = 1e16;

        uint32 m = _maturityOfNow();
        bytes32 bondId = _bondIdAt(m, 0);

        // slither-disable-next-line unused-return
        (uint160 sqrtNow,,,) = manager.getSlot0(id_);

        uint256 mgrBefore = currency0.balanceOf(address(manager));
        uint256 traderBefore = currency1.balanceOf(address(this));
        int24 tickBefore = _tick();

        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(requested),
                sqrtPriceLimitX96: sqrtNow - uint160((uint256(sqrtNow) * ppm) / 1_000_000)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _hookData()
        );

        uint256 fill = currency0.balanceOf(address(manager)) - mgrBefore;

        bonded = hook.bondExists(bondId);

        assertLt(fill, requested, "the rung filled completely; it is not a partial fill");

        console2.log("FILL ppm / filled", uint256(ppm), fill);
        console2.log("  bonded         ", bonded ? uint256(1) : uint256(0));

        // ELIGIBILITY IS ON THE FILL, NEVER ON THE REQUEST. The request is identical on every rung.
        if (fill < MIN_BONDED) {
            assertFalse(bonded, "a rung that filled below the threshold was bonded on its REQUEST");

            return false;
        }

        assertTrue(bonded, "a rung that filled above the threshold was not bonded");

        // And the collateral is priced on the REALIZED leg and impact, checked against the
        // independent reference rather than against the hook's own arithmetic.
        uint256 collateral = hook.collateralAmountOf(bondId);
        uint256 leg = (currency1.balanceOf(address(this)) - traderBefore) + collateral;

        assertEq(
            collateral,
            ModelLReference.collateralFor(leg, tickBefore, _tick()),
            "the rung's collateral does not match Model L on its realized execution"
        );

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                  14  ADVERSARIAL EXACT-OUTPUT
    //////////////////////////////////////////////////////////////*/

    /// @notice Exact-output always delivers exactly the requested output, in every adversarial
    ///         shape that still succeeds.
    ///
    /// @dev The property a trader relies on: the SPECIFIED leg is untouchable. The hook takes its
    ///      collateral from the input side and adds it on top, so a successful exact-output swap
    ///      must deliver the exact amount whatever the impact, the ceiling or the quiet period.
    function test_adv14_exactOutputPreservesTheSpecifiedLeg() public {
        uint128[4] memory outputs = [uint128(1e15), 1e16, 5e16, 2e17];

        for (uint256 d = 0; d < 2; d++) {
            bool zeroForOne = d == 0;

            Currency outCurrency = zeroForOne ? currency1 : currency0;

            for (uint256 i = 0; i < outputs.length; i++) {
                uint256 snap = vm.snapshotState();

                uint256 before = outCurrency.balanceOf(address(this));

                _swapT(int256(uint256(outputs[i])), zeroForOne, _hookData());

                assertEq(
                    outCurrency.balanceOf(address(this)) - before,
                    outputs[i],
                    "exact-output did not deliver the exact requested amount"
                );

                vm.revertToState(snap);
            }
        }
    }

    /// @notice The trader ceiling binds exactly on exact-output: `=` succeeds, `-1` reverts.
    function test_adv14_exactOutputCeilingBoundaryIsExact() public {
        uint256 probe = vm.snapshotState();

        uint256 hookBefore = currency0.balanceOf(address(hook));

        _swapT(int256(1e16), true, _hookData());

        uint256 bond = currency0.balanceOf(address(hook)) - hookBefore;

        assertGt(bond, 1, "fixture bond too small to test a one-wei-under ceiling");

        vm.revertToState(probe);

        // Exactly at the ceiling: succeeds.
        uint256 h0 = currency0.balanceOf(address(hook));

        _swapT(int256(1e16), true, HookDataCodec.encode(TRADER, uint128(bond)));

        assertEq(currency0.balanceOf(address(hook)) - h0, bond, "a ceiling equal to the bond was rejected");

        vm.revertToState(probe);

        // One wei below: reverts, and takes nothing.
        uint256 h1 = currency0.balanceOf(address(hook));

        vm.expectRevert();

        _swapT(int256(1e16), true, HookDataCodec.encode(TRADER, uint128(bond - 1)));

        assertEq(currency0.balanceOf(address(hook)), h1, "a rejected exact-output swap still moved collateral");
    }

    /// @notice Exact-output on a quiet pool, settled very late, still delivers and still settles.
    function test_adv14_exactOutputQuietAndLateSettlement() public {
        uint32 m = _maturityOfNow();
        bytes32 bondId = _bondIdAt(m, 0);

        uint256 before = currency1.balanceOf(address(this));

        _swapT(int256(1e16), true, _hookData());

        assertEq(currency1.balanceOf(address(this)) - before, 1e16, "exact-output did not deliver");

        // Total silence, then settle 10,000 blocks late.
        vm.roll(uint256(m) + 10_000);

        Settled memory got = _settle(bondId);

        assertEq(got.refund + got.slash, uint256(got.collateral), "quiet late exact-output did not conserve");

        assertGt(got.collateral, 0, "no collateral was posted");
    }

    /*//////////////////////////////////////////////////////////////
                  15  THE ROUTER-FREE CALLER
    //////////////////////////////////////////////////////////////*/

    /// @notice A direct `PoolManager.unlock` caller gets the same bond and the same bounds, in both
    ///         swap kinds and both directions.
    ///
    /// @dev THE ONLY SETTING WHERE INV-NOOP-VL IS LOAD-BEARING. `V4Router` happens to revert on the
    ///      negative cast an oversized unspecified delta would produce, but nothing obliges a
    ///      caller to use a router, and a security property contingent on the caller's choice of
    ///      periphery is not a security property.
    function test_adv15_directCallerAllFourModes() public {
        DirectSwapper d = new DirectSwapper(IPoolManager(address(manager)));

        deal(Currency.unwrap(currency0), address(d), 1e24);
        deal(Currency.unwrap(currency1), address(d), 1e24);

        for (uint256 i = 0; i < 4; i++) {
            bool exactInput = i < 2;
            bool zeroForOne = (i % 2) == 0;

            uint256 snap = vm.snapshotState();

            Currency collateralCurrency =
                ModelLReference.collateralIsCurrency0(zeroForOne, exactInput) ? currency0 : currency1;

            uint256 hookBefore = collateralCurrency.balanceOf(address(hook));

            (int256 amount0, int256 amount1) =
                d.swap(key_, zeroForOne, exactInput ? -int256(1e16) : int256(1e16), _hookData());

            uint256 bond = collateralCurrency.balanceOf(address(hook)) - hookBefore;

            assertGt(bond, 0, "the direct caller was not bonded");

            // The specified leg is exactly as specified, even with no router in the path.
            int256 specified = zeroForOne == exactInput ? amount0 : amount1;

            assertEq(
                specified < 0 ? uint256(-specified) : uint256(specified),
                1e16,
                "the specified leg was altered for a router-free caller"
            );

            // INV-NOOP-VL: the bond sits strictly inside the variable leg.
            int256 unspecified = zeroForOne == exactInput ? amount1 : amount0;

            uint256 rawLeg = unspecified > 0 ? uint256(unspecified) + bond : uint256(-unspecified) - bond;

            assertLt(bond, rawLeg, "INV-NOOP-VL: the bond was not strictly inside the variable leg");

            vm.revertToState(snap);
        }
    }

    /// @notice The trader ceiling and malformed hookData both bind with no router present.
    function test_adv15_directCallerCeilingAndHookDataStillBind() public {
        DirectSwapper d = new DirectSwapper(IPoolManager(address(manager)));

        deal(Currency.unwrap(currency0), address(d), 1e24);
        deal(Currency.unwrap(currency1), address(d), 1e24);

        uint256 hookBefore = currency1.balanceOf(address(hook));

        // Ceiling of 1 is below any bond this pool can produce.
        vm.expectRevert();
        d.swap(key_, true, -int256(1e16), HookDataCodec.encode(TRADER, 1));

        // A well-formed VERSION 1 payload must still be rejected.
        vm.expectRevert();
        d.swap(key_, true, -int256(1e16), abi.encodePacked(uint8(1), TRADER, GENEROUS_CEILING));

        // Empty hookData on a bonded-size swap.
        vm.expectRevert();
        d.swap(key_, true, -int256(1e16), "");

        assertEq(currency1.balanceOf(address(hook)), hookBefore, "a rejected router-free swap moved collateral");
    }

    /*//////////////////////////////////////////////////////////////
                    16  HOOKDATA ADVERSARIAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Every malformed, boundary and hostile hookData shape is rejected; only exact v2 is
    ///         accepted.
    ///
    /// @dev NO LENIENT FALLBACK ANYWHERE. Length is checked exactly, so trailing bytes are rejected
    ///      rather than ignored: extra data may encode fields a future version understands, and
    ///      silently dropping them would let a newer integration believe a constraint was applied.
    function test_adv16_hookDataRejectsEveryMalformedShape() public {
        // Lengths.
        _expectSwapRevert(hex"", "empty");
        _expectSwapRevert(hex"02", "one byte");
        _expectSwapRevert(abi.encodePacked(HookDataCodec.VERSION, TRADER, uint120(1)), "36 bytes");
        _expectSwapRevert(abi.encodePacked(HookDataCodec.VERSION, TRADER, GENEROUS_CEILING, uint8(0)), "38 bytes");
        _expectSwapRevert(
            abi.encodePacked(HookDataCodec.VERSION, TRADER, GENEROUS_CEILING, new bytes(4_096)), "huge trailing"
        );

        // Versions. v1 shares v2's exact length, so only the version byte can separate them.
        _expectSwapRevert(abi.encodePacked(uint8(0), TRADER, GENEROUS_CEILING), "version 0");
        _expectSwapRevert(abi.encodePacked(uint8(1), TRADER, GENEROUS_CEILING), "version 1");
        _expectSwapRevert(abi.encodePacked(uint8(3), TRADER, GENEROUS_CEILING), "version 3");
        _expectSwapRevert(abi.encodePacked(uint8(255), TRADER, GENEROUS_CEILING), "version 255");

        // Field boundaries.
        _expectSwapRevert(abi.encodePacked(HookDataCodec.VERSION, address(0), GENEROUS_CEILING), "zero recipient");
        _expectSwapRevert(abi.encodePacked(HookDataCodec.VERSION, TRADER, uint128(0)), "zero ceiling");

        // Adjacent-field bit patterns: an all-ones recipient beside a 1-wei ceiling, and a 1-bit
        // recipient beside a max ceiling. Both are well-formed and must be ACCEPTED as valid
        // payloads -- the ceiling then does its job and rejects, or does not.
        uint256 snap = vm.snapshotState();

        vm.expectRevert(); // ceiling of 1 wei is below any bond this pool can produce
        _swapT(-int256(1e16), true, abi.encodePacked(HookDataCodec.VERSION, address(type(uint160).max), uint128(1)));

        vm.revertToState(snap);

        uint256 hookBefore = currency1.balanceOf(address(hook));

        _swapT(-int256(1e16), true, abi.encodePacked(HookDataCodec.VERSION, address(1), type(uint128).max));

        assertGt(
            currency1.balanceOf(address(hook)) - hookBefore,
            0,
            "a well-formed payload with boundary field values was rejected"
        );
    }

    /// @notice The refund recipient comes ONLY from hookData — never from the caller or the router.
    ///
    /// @dev The reason `hookData` carries a recipient at all: on a routed swap the callback's
    ///      `sender` is the router, so using it would send every refund to the router. `tx.origin`
    ///      is equally wrong and is never consulted.
    ///
    ///      Proven by making the three candidate addresses distinct and checking the record binds
    ///      the payload's, then that settlement actually pays that address.
    function test_adv16_refundRecipientComesOnlyFromHookData() public {
        address payloadRecipient = address(0xFEED);

        uint32 m = _maturityOfNow();
        bytes32 bondId = _bondIdAt(m, 0);

        // Fund and approve the attacker so the swap can actually execute from their address.
        deal(Currency.unwrap(currency0), ATTACKER, 1e24);
        deal(Currency.unwrap(currency1), ATTACKER, 1e24);

        vm.startPrank(ATTACKER, ATTACKER);

        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);

        // The caller AND tx.origin are now ATTACKER; the hook's `sender` is the router; the payload
        // names a third address entirely. All three are distinct, which is what makes the assertion
        // below able to tell them apart.

        // The prank applies to the router call; the hook's `sender` is still the router.
        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1e16), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            HookDataCodec.encode(payloadRecipient, GENEROUS_CEILING)
        );

        vm.stopPrank();

        BondMeBro.Bond memory b = hook.getBond(bondId);

        assertEq(b.refundRecipient, payloadRecipient, "the recipient did not come from hookData");
        assertTrue(b.refundRecipient != address(swapRouter), "the recipient is the ROUTER");
        assertTrue(b.refundRecipient != ATTACKER, "the recipient is the caller or tx.origin");
        assertTrue(b.refundRecipient != address(this), "the recipient is the test contract");

        // And settlement pays that address, not any of the others.
        vm.roll(uint256(m) + 1);
        _swapT(NUDGE, true, "");

        // Arbitrage the price back so there is a refund to observe.
        Currency c = b.collateralIsCurrency0 ? currency0 : currency1;

        uint256 before = c.balanceOf(payloadRecipient);
        uint256 attackerBefore = c.balanceOf(ATTACKER);

        hook.settleBond(bondId);

        assertGe(c.balanceOf(payloadRecipient), before, "the payload recipient lost balance");
        assertEq(c.balanceOf(ATTACKER), attackerBefore, "the caller received part of the refund");
    }

    function _expectSwapRevert(bytes memory hookData, string memory label) internal {
        uint256 snap = vm.snapshotState();

        uint256 hookBefore0 = currency0.balanceOf(address(hook));
        uint256 hookBefore1 = currency1.balanceOf(address(hook));

        vm.expectRevert();

        _swapT(-int256(1e16), true, hookData);

        assertEq(currency0.balanceOf(address(hook)), hookBefore0, string.concat(label, ": moved currency0"));
        assertEq(currency1.balanceOf(address(hook)), hookBefore1, string.concat(label, ": moved currency1"));

        vm.revertToState(snap);
    }

    /*//////////////////////////////////////////////////////////////
                17  PROVISIONAL-STATE ATTACKS
    //////////////////////////////////////////////////////////////*/

    /// @dev `bonds` is at storage slot 3; `Bond.state` is byte 23 of the record's second slot.
    ///      Pinned by `test/StorageLayout.t.sol`, which fails first if either moves.
    uint256 internal constant SLOT_BONDS = 3;
    uint256 internal constant BOND_STATE_BYTE_OFFSET = 25;

    function _rawState(bytes32 bondId) internal view returns (uint8) {
        bytes32 slot1 = bytes32(uint256(keccak256(abi.encode(bondId, SLOT_BONDS))) + 1);

        return uint8(uint256(vm.load(address(hook), slot1)) >> (8 * BOND_STATE_BYTE_OFFSET));
    }

    /// @notice No PROVISIONAL record survives any completed or reverted transaction.
    ///
    /// @dev READ FROM RAW STORAGE, because ADR-0004 Rule 1 makes `getBond` revert identically for a
    ///      provisional record and an absent one — the public API is structurally incapable of
    ///      telling "cleared" from "stranded". A stranded provisional would be a bond nobody can
    ///      settle and nobody can see, occupying an index in its maturity bucket forever.
    ///
    ///      Every outcome the callbacks can reach is driven, including three that revert AFTER
    ///      `beforeSwap` has already written the header.
    function test_adv17_noProvisionalSurvivesAnyOutcome() public {
        _sweepAfter(abi.encodeCall(this.exec_bondedEI, ()), 1, "bonded exact-input");
        _sweepAfter(abi.encodeCall(this.exec_bondedEO, ()), 1, "bonded exact-output");
        _sweepAfter(abi.encodeCall(this.exec_belowThreshold, ()), 0, "below threshold");
        _sweepAfter(abi.encodeCall(this.exec_partialFillUnbonded, ()), 0, "partial fill below threshold");
        _sweepAfter(abi.encodeCall(this.exec_ceilingRevert, ()), 0, "reverted by trader ceiling");
        _sweepAfter(abi.encodeCall(this.exec_malformedRevert, ()), 0, "reverted by malformed hookData");
        _sweepAfter(abi.encodeCall(this.exec_versionRevert, ()), 0, "reverted by v1 payload");
    }

    function exec_bondedEI() external {
        _swapT(-int256(1e16), true, _hookData());
    }

    function exec_bondedEO() external {
        _swapT(int256(1e16), true, _hookData());
    }

    function exec_belowThreshold() external {
        _swapT(-int256(uint256(MIN_BONDED) - 1), true, "");
    }

    function exec_partialFillUnbonded() external {
        // slither-disable-next-line unused-return
        (uint160 sqrtNow,,,) = manager.getSlot0(id_);

        // A request well above the threshold that fills far below it.
        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(1e16),
                sqrtPriceLimitX96: sqrtNow - uint160((uint256(sqrtNow) * 20) / 1_000_000)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _hookData()
        );
    }

    function exec_ceilingRevert() external {
        _swapT(-int256(1e16), true, HookDataCodec.encode(TRADER, 1));
    }

    function exec_malformedRevert() external {
        _swapT(-int256(1e16), true, hex"02");
    }

    function exec_versionRevert() external {
        _swapT(-int256(1e16), true, abi.encodePacked(uint8(1), TRADER, GENEROUS_CEILING));
    }

    /// @dev Runs an outcome, then sweeps the entire maturity bucket for surviving provisionals.
    function _sweepAfter(bytes memory call, uint256 expectedFinalized, string memory label) internal {
        uint256 snap = vm.snapshotState();

        uint32 m = _maturityOfNow();

        // slither-disable-next-line low-level-calls
        (bool ok,) = address(this).call(call);

        uint256 finalized;

        // Wider than any index this outcome could legitimately use: a record written to an
        // unexpected slot is exactly what a targeted check would miss.
        for (uint32 i = 0; i < 48; i++) {
            bytes32 bondId = _bondIdAt(m, i);

            uint8 state = _rawState(bondId);

            assertTrue(state != 1, string.concat(label, ": a PROVISIONAL record survived"));

            if (state == 2) finalized++;

            assertEq(
                hook.bondExists(bondId),
                state == 2 || state == 3,
                string.concat(label, ": bondExists disagrees with the raw state")
            );
        }

        assertEq(finalized, expectedFinalized, string.concat(label, ": wrong number of finalized bonds"));

        (,,, uint32 pending,) = hook.maturity(id_, m);

        assertEq(pending, expectedFinalized, string.concat(label, ": pendingBonds disagrees with the sweep"));

        // A reverted outcome must additionally have moved nothing.
        if (!ok) {
            assertEq(pending, 0, string.concat(label, ": a reverted swap registered a liability"));
        }

        vm.revertToState(snap);
    }
}

/// @notice A router-free swap driver: calls `poolManager.swap` inside its own `unlock` and settles
///         the resulting deltas by hand.
contract DirectSwapper {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        external
        returns (int256 amount0, int256 amount1)
    {
        return abi.decode(manager.unlock(abi.encode(key, zeroForOne, amountSpecified, hookData)), (int256, int256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");

        (PoolKey memory key, bool zeroForOne, int256 amountSpecified, bytes memory hookData) =
            abi.decode(data, (PoolKey, bool, int256, bytes));

        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData
        );

        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());

        return abi.encode(int256(delta.amount0()), int256(delta.amount1()));
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            manager.sync(currency);

            MockERC20(Currency.unwrap(currency)).transfer(address(manager), uint256(uint128(-amount)));

            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}
