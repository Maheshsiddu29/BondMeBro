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

import {BondMeBro, HOOK_FLAGS} from "../../src/BondMeBro.sol";
import {HookDataCodec} from "../../src/libraries/HookDataCodec.sol";

/// @title AuditSettlementAndSolvency
///
/// @notice AUDIT ONLY. Independent checks on settlement authority, batch behaviour, solvency and
///         the block-start griefing surface. Nothing here calls a production helper and compares it
///         to itself; every expectation is computed from token balances or from first principles.
contract AuditSettlementAndSolvencyTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    BondMeBro internal hook;

    PoolKey internal key_;
    PoolId internal id_;

    address internal constant TRADER = address(0xB0B);
    address internal constant STRANGER = address(0xDEAD);
    address internal constant VICTIM = address(0xCAFE);

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
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e19, salt: bytes32(uint256(1))
            }),
            ""
        );

        hook.setPoolConfig(key_, 1e15, 1e15, 10_000, 10_000, true);
    }

    function _data(address who, uint128 ceiling) internal pure returns (bytes memory) {
        return HookDataCodec.encode(who, ceiling);
    }

    function _swap(int256 amount, bool zeroForOne, bytes memory d) internal {
        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            d
        );
    }

    function _nextBondId() internal view returns (bytes32) {
        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        // slither-disable-next-line unused-return
        (,,, uint32 pending,) = hook.maturity(id_, m);

        return keccak256(abi.encode(id_, m, pending));
    }

    function externalSwap(int256 amount, bool zeroForOne, bytes memory d) external {
        require(msg.sender == address(this), "self only");

        _swap(amount, zeroForOne, d);
    }

    /*//////////////////////////////////////////////////////////////
                § 21 -- SETTLEMENT CALLER CANNOT REDIRECT VALUE
    //////////////////////////////////////////////////////////////*/

    /// @notice A stranger settling someone else's bond gains nothing and changes nothing.
    function test_audit_settlementCallerGainsNothing() public {
        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        bytes32 bondId = _nextBondId();

        _swap(-1e16, true, _data(TRADER, type(uint128).max));

        uint256 collateral = hook.collateralAmountOf(bondId);

        vm.roll(m + 1);

        _swap(-1e11, true, _data(TRADER, type(uint128).max));

        uint256 strangerC0 = currency0.balanceOf(STRANGER);
        uint256 strangerC1 = currency1.balanceOf(STRANGER);
        uint256 traderBefore = currency1.balanceOf(TRADER);
        uint256 potBefore = hook.insurancePot(id_, currency1);

        vm.prank(STRANGER);
        hook.settleBond(bondId);

        assertEq(currency0.balanceOf(STRANGER), strangerC0, "settler received currency0");
        assertEq(currency1.balanceOf(STRANGER), strangerC1, "settler received currency1");

        uint256 refund = currency1.balanceOf(TRADER) - traderBefore;
        uint256 slash = hook.insurancePot(id_, currency1) - potBefore;

        assertEq(refund + slash, collateral, "settlement did not conserve");

        console2.log("collateral / refund / slash", collateral, refund, slash);
        console2.log("settler balance delta: zero in both currencies");
    }

    /*//////////////////////////////////////////////////////////////
                    § 22 -- BATCH SETTLEMENT BEHAVIOUR
    //////////////////////////////////////////////////////////////*/

    /// @notice A duplicated bond id inside one `settleMany` batch reverts the whole batch.
    ///
    /// @dev The important property is that a duplicate cannot pay a refund twice. Atomic rejection
    ///      is the safe outcome; this test records WHICH it is so integrators are not surprised.
    function test_audit_settleManyRejectsDuplicateIds() public {
        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        bytes32 a = _nextBondId();

        _swap(-1e16, true, _data(TRADER, type(uint128).max));

        vm.roll(m + 1);

        _swap(-1e11, true, _data(TRADER, type(uint128).max));

        bytes32[] memory batch = new bytes32[](2);
        batch[0] = a;
        batch[1] = a; // the same bond, twice

        uint256 traderBefore = currency1.balanceOf(TRADER);
        uint256 potBefore = hook.insurancePot(id_, currency1);

        vm.expectRevert();

        hook.settleMany(batch);

        assertEq(currency1.balanceOf(TRADER), traderBefore, "a reverted batch still paid a refund");
        assertEq(hook.insurancePot(id_, currency1), potBefore, "a reverted batch still moved the pot");

        // ...and the bond is still settleable on its own afterwards.
        hook.settleBond(a);

        console2.log("duplicate batch reverted atomically; single settlement still works");
    }

    /// @notice An empty batch is a no-op rather than a revert.
    function test_audit_settleManyEmptyBatch() public {
        bytes32[] memory batch = new bytes32[](0);

        hook.settleMany(batch);

        console2.log("empty settleMany batch: accepted as a no-op");
    }

    /*//////////////////////////////////////////////////////////////
                § 26 -- SOLVENCY WITH A SHARED CURRENCY
    //////////////////////////////////////////////////////////////*/

    /// @notice The hook's physical balance always covers outstanding refund liability plus the pot.
    ///
    /// @dev Liability is reconstructed from the BOND RECORDS, independently of the hook's own
    ///      accounting: for every unsettled bond, `leg * storedBps / BPS`.
    function test_audit_solvencyAcrossMixedModesAndOrders() public {
        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        bytes32[] memory ids = new bytes32[](4);

        // Four bonds spanning both kinds and both directions, all in one maturity bucket.
        ids[0] = _nextBondId();
        _swap(-1e16, true, _data(TRADER, type(uint128).max));

        ids[1] = _nextBondId();
        _swap(-1e16, false, _data(TRADER, type(uint128).max));

        ids[2] = _nextBondId();
        _swap(int256(1e16), true, _data(TRADER, type(uint128).max));

        ids[3] = _nextBondId();
        _swap(int256(1e16), false, _data(TRADER, type(uint128).max));

        _assertSolvent("after opening four bonds");

        vm.roll(m + 1);

        _swap(-1e11, true, _data(TRADER, type(uint128).max));

        _assertSolvent("after maturity");

        // Settle in a deliberately awkward order.
        uint8[4] memory order = [3, 1, 0, 2];

        for (uint256 i = 0; i < 4; i++) {
            bytes32 bondId = ids[order[i]];

            if (!hook.bondExists(bondId)) continue;

            hook.settleBond(bondId);

            _assertSolvent("mid-settlement");
        }

        _assertSolvent("after all settlements");

        console2.log("solvency held at every step across four mixed-mode bonds");
    }

    /// @dev Physical balance >= outstanding refundable liability + insurance pot, per currency.
    function _assertSolvent(string memory stage) internal view {
        uint32 m = uint32(block.number) + hook.OBSERVATION_BLOCKS();

        m; // unused; liability is walked from the buckets below

        uint256 liab0;
        uint256 liab1;

        // Walk every bucket this test could have touched.
        for (uint32 mm = 1; mm <= uint32(block.number) + hook.OBSERVATION_BLOCKS(); mm++) {
            // slither-disable-next-line unused-return
            (,,, uint32 pending,) = hook.maturity(id_, mm);

            for (uint32 i = 0; i < pending + 4; i++) {
                bytes32 bondId = keccak256(abi.encode(id_, mm, i));

                if (!hook.bondExists(bondId)) continue;

                BondMeBro.Bond memory b = hook.getBond(bondId);

                // OUTSTANDING liability is FINALIZED only. `bondExists` deliberately returns true
                // for SETTLED as well -- its NatSpec says so explicitly -- and `collateralAmountOf`
                // keeps returning the ORIGINAL collateral after settlement. Composing the two
                // without this filter over-counts every settled bond, which is precisely the
                // mistake an integrator is most likely to make here.
                if (b.state != BondMeBro.BondState.FINALIZED) continue;

                uint256 c = (uint256(b.variableLegAmount) * uint256(b.collateralBps)) / hook.BPS();

                if (b.collateralIsCurrency0) liab0 += c;
                else liab1 += c;
            }
        }

        uint256 held0 = currency0.balanceOf(address(hook));
        uint256 held1 = currency1.balanceOf(address(hook));

        console2.log("STAGE", stage);
        console2.log("  c0 held / liab+pot", held0, liab0 + hook.insurancePot(id_, currency0));
        console2.log("  c1 held / liab+pot", held1, liab1 + hook.insurancePot(id_, currency1));

        assertGe(held0, liab0 + hook.insurancePot(id_, currency0), string.concat("c0 insolvent: ", stage));
        assertGe(held1, liab1 + hook.insurancePot(id_, currency1), string.concat("c1 insolvent: ", stage));
    }

    /*//////////////////////////////////////////////////////////////
          § 36 -- GRIEFING: A TIGHT maxBondAmount CAN BE REVERTED
    //////////////////////////////////////////////////////////////*/

    /// @notice BMB-02. An attacker who moves the price first in a block can force a victim's swap
    ///         to revert, if the victim set a quote-derived `maxBondAmount`.
    ///
    /// @dev This is the concrete cost of the `INTEGRATION.md` policy being advisory rather than
    ///      enforced. A victim whose integrator sizes `maxBondAmount` from an undisplaced quote is
    ///      denied service for as long as the attacker keeps displacing blocks.
    function test_audit_BMB02_tightMaxBondCanBeGriefedIntoReverting() public {
        // The victim quotes in a clean block and sizes a ceiling with 4x headroom.
        uint256 snap = vm.snapshotState();

        uint256 hookBefore = currency1.balanceOf(address(hook));

        _swap(-1e16, true, _data(VICTIM, type(uint128).max));

        uint128 honestCeiling = uint128((currency1.balanceOf(address(hook)) - hookBefore) * 4);

        vm.revertToState(snap);

        console2.log("victim's quote-derived ceiling (4x)", honestCeiling);

        // The attacker displaces the block first.
        _swap(-int256(uint256(4e17)), true, _data(TRADER, type(uint128).max));

        bool victimReverted;

        try this.externalSwap(-1e16, true, _data(VICTIM, honestCeiling)) {
            victimReverted = false;
        } catch {
            victimReverted = true;
        }

        console2.log("victim swap reverted?", victimReverted ? 1 : 0);

        assertTrue(victimReverted, "the griefing path did not reproduce");

        // ...and the same victim swap succeeds with the documented unbounded ceiling.
        vm.revertToState(snap);

        _swap(-int256(uint256(4e17)), true, _data(TRADER, type(uint128).max));

        _swap(-1e16, true, _data(VICTIM, type(uint128).max));

        console2.log("same swap ACCEPTED with maxBondAmount = type(uint128).max");
    }
}
