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

/// @notice T5B final verification — INV-SOLVENCY across two pools sharing one physical currency.
///
/// @dev WHY THIS SUITE EXISTS SEPARATELY. Every other settlement test drives a single pool, and on
///      a single pool the aggregation INV-SOLVENCY performs is invisible: with one pool, "sum the
///      liabilities across every pool using this currency" and "read this pool's liability" are
///      the same number. The property only has teeth when two PoolIds share one ERC-20.
///
///      THE FAILURE MODE BEING RULED OUT. The hook holds ONE balance per ERC-20, but liabilities
///      are keyed per pool. A solvency check written per pool compares each pool's liability
///      against that one shared balance and passes both times while the hook is insolvent:
///
///          hook holds 100 USDC;  pool A owes 80;  pool B owes 80
///          80 <= 100 PASS        80 <= 100 PASS        160 owed — insolvent
///
///      `test_perPoolOnlyCheckIsUnsound` demonstrates that concretely rather than arguing it: it
///      drives the hook into real insolvency and shows the per-pool form passing anyway.
///
///      NO PRODUCTION ACCOUNTING WAS ADDED FOR THIS. `insurancePot` is already public and keyed
///      per pool, and unsettled liability is read from the bond records the test itself created.
contract SharedCurrencySolvencyTest is Test, Deployers {
    BondMeBro internal hook;

    /// @dev The shared currency. Both pools take bonds denominated in this one ERC-20, so both
    ///      pools' liabilities land in a single hook balance.
    MockERC20 internal usdc;
    MockERC20 internal tokenX;
    MockERC20 internal tokenY;

    PoolKey internal keyA;
    PoolKey internal keyB;
    PoolId internal idA;
    PoolId internal idB;

    /// @dev True when USDC sorted low in that pool, i.e. USDC is currency0 there.
    bool internal usdcIsZeroInA;
    bool internal usdcIsZeroInB;

    Currency internal usdcCurrency;

    address internal constant TRADER_A = address(0xA11CE);
    address internal constant TRADER_B = address(0xB0B);

    uint128 internal constant MIN_BONDED = 1e15;
    uint96 internal constant MIN_BONDED_1 = 1e15;
    uint16 internal constant BOND_BPS = 25;
    uint16 internal constant REFUND_TOL = 5;
    uint128 internal constant GENEROUS_CEILING = type(uint128).max;

    /// @dev Bonded, and large enough against the thin fixture liquidity to move the tick past the
    ///      noise floor so settlements produce real slashes rather than trivial full refunds.
    int256 internal constant BONDED = -1e16;

    function setUp() public {
        deployFreshManagerAndRouters();

        // All three tokens share 18 decimals. Decimal asymmetry is a real concern but it is not
        // the variable under test here — `BondThresholds.t.sol` covers it. Keeping them equal
        // means the thresholds are directly comparable and the solvency arithmetic stays legible.
        usdc = new MockERC20("USD Coin", "USDC", 18);
        tokenX = new MockERC20("Token X", "TKNX", 18);
        tokenY = new MockERC20("Token Y", "TKNY", 18);

        usdcCurrency = Currency.wrap(address(usdc));

        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(BondMeBro).creationCode, abi.encode(manager, address(this)));
        hook = new BondMeBro{salt: salt}(IPoolManager(address(manager)), address(this));
        assertEq(address(hook), predicted, "mined address mismatch");

        _mintAndApprove(usdc);
        _mintAndApprove(tokenX);
        _mintAndApprove(tokenY);

        (keyA, idA, usdcIsZeroInA) = _createPool(usdc, tokenX, 3000, 60);
        (keyB, idB, usdcIsZeroInB) = _createPool(usdc, tokenY, 500, 10);

        // Two genuinely distinct pools.
        assertTrue(PoolId.unwrap(idA) != PoolId.unwrap(idB), "fixture: pools must be distinct");

        // Sharing one physical ERC-20 — the whole point.
        assertTrue(
            Currency.unwrap(usdcIsZeroInA ? keyA.currency0 : keyA.currency1) == address(usdc)
                && Currency.unwrap(usdcIsZeroInB ? keyB.currency0 : keyB.currency1) == address(usdc),
            "fixture: both pools must use the same USDC contract"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 FIXTURE
    //////////////////////////////////////////////////////////////*/

    function _mintAndApprove(MockERC20 token) internal {
        token.mint(address(this), 1e30);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
    }

    /// @dev Creates a pool holding `a` and `b`, seeded thin so swaps move the tick meaningfully.
    /// @return key The pool key. @return id Its PoolId. @return aIsZero Whether `a` is currency0.
    function _createPool(MockERC20 a, MockERC20 b, uint24 fee, int24 tickSpacing)
        internal
        returns (PoolKey memory key, PoolId id, bool aIsZero)
    {
        aIsZero = address(a) < address(b);

        (Currency c0, Currency c1) = aIsZero
            ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
            : (Currency.wrap(address(b)), Currency.wrap(address(a)));

        key = PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(address(hook))});
        id = key.toId();

        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -tickSpacing * 1000, tickUpper: tickSpacing * 1000, liquidityDelta: 1e18, salt: bytes32(0)
            }),
            ""
        );

        hook.setPoolConfig(key, MIN_BONDED, MIN_BONDED_1, 10_000, 10_000, true);
    }

    /// @dev Swaps so that the resulting bond's COLLATERAL is denominated in USDC, whichever side
    ///      USDC sorted to in that pool.
    ///
    ///      THE DIRECTION INVERTED IN P-L2-3/4, and the suite's entire premise depends on getting
    ///      this right.
    ///
    ///      This helper used to make USDC the swap's INPUT, because collateral was always carved
    ///      out of the input. Under ADR-0006 collateral comes from the VARIABLE leg, and for an
    ///      exact-input swap that is the OUTPUT -- so the old direction now produces bonds
    ///      denominated in tokenX and tokenY, one per pool, sharing nothing.
    ///
    ///      That would not have failed loudly in the interesting way. Two pools with liabilities
    ///      in two DIFFERENT currencies trivially satisfy every aggregation property this file
    ///      exists to test, so the suite would have gone on passing while no longer exercising the
    ///      shared-balance failure mode at all. The swaps are therefore inverted to BUY USDC,
    ///      which puts the collateral back in the one currency both pools share.
    ///
    ///      This is precisely the mistake INV-L2-10 warns about, applied to a test fixture rather
    ///      than to production code: *"the collateral currency must be READ from the bond record,
    ///      never inferred from the swap direction."*
    function _swapSpendingUsdc(PoolKey memory key, bool usdcIsZero, int256 amountSpecified, address recipient)
        internal
    {
        // Exact-input, with USDC on the OUTPUT side: `zeroForOne` must point AWAY from USDC.
        bool zeroForOne = !usdcIsZero;

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            HookDataCodec.encode(recipient, GENEROUS_CEILING)
        );
    }

    /// @dev A tiny unbonded swap, used only to advance the accumulator and freeze maturities.
    function _nudge(PoolKey memory key, bool usdcIsZero) internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: usdcIsZero,
                amountSpecified: -1e12,
                sqrtPriceLimitX96: usdcIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _bondId(PoolId id, uint32 maturityBlock, uint32 index) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, maturityBlock, index));
    }

    function _maturityOfNow() internal view returns (uint32) {
        return uint32(block.number) + hook.OBSERVATION_BLOCKS();
    }

    /// @dev Asserts every listed bond really is held in USDC.
    ///
    ///      A non-vacuity guard for the inversion above: if the direction were ever flipped back,
    ///      the aggregation tests would still pass on trivially separate currencies. This makes
    ///      that regression fail where it is caused rather than silently weakening the suite.
    function _assertAllCollateralIsUsdc(bytes32[] memory ids, bool usdcIsZero, string memory label) internal view {
        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(
                hook.getBond(ids[i]).collateralIsCurrency0,
                usdcIsZero,
                string.concat(label, ": bond is not collateralised in USDC; the shared-currency premise is broken")
            );
        }
    }

    /// @dev Sum of collateral still owed to traders in one pool, over the bonds this test made.
    function _unsettledIn(bytes32[] memory ids) internal view returns (uint256 total) {
        for (uint256 i = 0; i < ids.length; i++) {
            BondMeBro.Bond memory bond = hook.getBond(ids[i]);

            // FINALIZED (2) is still owed; SETTLED (3) is not.
            if (uint8(bond.state) == 2) total += hook.collateralAmountOf(ids[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                      THE SHARED-CURRENCY SCENARIO
    //////////////////////////////////////////////////////////////*/

    /// @notice Builds real, simultaneous USDC liabilities of all four kinds across two pools, then
    ///         proves the hook's single USDC balance covers their SUM.
    ///
    /// @dev The end state deliberately contains every component the aggregate must include:
    ///
    ///          unsettled USDC in pool A   +   unsettled USDC in pool B
    ///        + USDC insurance pot in A    +   USDC insurance pot in B
    ///
    ///      Two bonds are opened per pool and one settled per pool, so each pool contributes both
    ///      a live liability and a retained slash at the same time.
    function test_aggregateSolvencyAcrossTwoPoolsSharingOneCurrency() public {
        (bytes32[] memory idsA, bytes32[] memory idsB) = _buildTwoPoolState();

        uint256 unsettledA = _unsettledIn(idsA);
        uint256 unsettledB = _unsettledIn(idsB);
        uint256 potA = hook.insurancePot(idA, usdcCurrency);
        uint256 potB = hook.insurancePot(idB, usdcCurrency);

        uint256 hookUsdc = usdc.balanceOf(address(hook));

        console2.log("hook USDC balance     :", hookUsdc);
        console2.log("unsettled  pool A     :", unsettledA);
        console2.log("unsettled  pool B     :", unsettledB);
        console2.log("insurance pot pool A  :", potA);
        console2.log("insurance pot pool B  :", potB);
        console2.log("AGGREGATE liability   :", unsettledA + unsettledB + potA + potB);

        // Every component is genuinely present — otherwise the aggregate would be trivially
        // satisfied by a state that never exercised the sum.
        assertGt(unsettledA, 0, "pool A has no live USDC liability");
        assertGt(unsettledB, 0, "pool B has no live USDC liability");
        assertGt(potA, 0, "pool A has no USDC insurance pot");
        assertGt(potB, 0, "pool B has no USDC insurance pot");

        // INV-SOLVENCY, in its aggregated form: ONE physical balance against the SUM of every
        // pool's liability in that currency.
        assertGe(
            hookUsdc,
            unsettledA + unsettledB + potA + potB,
            "hook holds less USDC than the aggregate of both pools' liabilities"
        );
    }

    /// @notice THE NEGATIVE PROOF: a per-pool solvency check passes on both pools while the hook
    ///         is genuinely insolvent in aggregate.
    ///
    /// @dev This is the test that justifies the aggregation. It builds the same real two-pool
    ///      state, then removes USDC from the hook — simulating a leak, a bug, or a bad accounting
    ///      path — until the balance sits ABOVE each pool's individual liability but BELOW their
    ///      sum. In that state:
    ///
    ///        - the per-pool form passes twice and reports the hook healthy;
    ///        - the aggregate form fails, correctly.
    ///
    ///      `deal` is used to shrink the balance because no production path can create insolvency
    ///      — which is the point. The unsound check is demonstrated to be unsound, not merely
    ///      asserted to be.
    function test_perPoolOnlyCheckIsUnsound() public {
        (bytes32[] memory idsA, bytes32[] memory idsB) = _buildTwoPoolState();

        uint256 liabilityA = _unsettledIn(idsA) + hook.insurancePot(idA, usdcCurrency);
        uint256 liabilityB = _unsettledIn(idsB) + hook.insurancePot(idB, usdcCurrency);

        uint256 larger = liabilityA > liabilityB ? liabilityA : liabilityB;
        uint256 aggregate = liabilityA + liabilityB;

        // Both pools must carry a real liability, or the construction proves nothing.
        assertGt(liabilityA, 0, "pool A has no USDC liability");
        assertGt(liabilityB, 0, "pool B has no USDC liability");

        // Drive the hook into genuine insolvency: enough to satisfy either pool alone, not both.
        uint256 insolventBalance = larger + 1;
        assertLt(insolventBalance, aggregate, "fixture: balance must sit below the aggregate");

        deal(address(usdc), address(hook), insolventBalance);

        console2.log("hook USDC (made insolvent):", insolventBalance);
        console2.log("liability pool A          :", liabilityA);
        console2.log("liability pool B          :", liabilityB);
        console2.log("AGGREGATE liability       :", aggregate);

        // THE UNSOUND CHECK — per pool, against the one shared balance. It passes. Twice.
        assertGe(insolventBalance, liabilityA, "per-pool check A passed, as the unsound form does");
        assertGe(insolventBalance, liabilityB, "per-pool check B passed, as the unsound form does");

        // THE SOUND CHECK — the aggregate. It correctly reports the insolvency the per-pool form
        // missed entirely.
        assertLt(insolventBalance, aggregate, "aggregate check failed to detect the insolvency");
    }

    /// @notice The same aggregate holds after settling everything: pots persist, liabilities go.
    /// @dev Confirms the aggregate tracks the state transition rather than only the mid-flight
    ///      snapshot — once every bond is settled the entire remaining liability is pot.
    function test_aggregateHoldsAfterEverythingIsSettled() public {
        (bytes32[] memory idsA, bytes32[] memory idsB) = _buildTwoPoolState();

        _settleAll(idsA);
        _settleAll(idsB);

        assertEq(_unsettledIn(idsA), 0, "pool A still has unsettled bonds");
        assertEq(_unsettledIn(idsB), 0, "pool B still has unsettled bonds");

        uint256 potA = hook.insurancePot(idA, usdcCurrency);
        uint256 potB = hook.insurancePot(idB, usdcCurrency);

        assertGe(usdc.balanceOf(address(hook)), potA + potB, "hook holds less USDC than both pools' pots combined");
    }

    /// @notice A pool's pot is credited only by its own bonds — pools do not cross-contaminate.
    /// @dev The counterpart to aggregation: liabilities SUM across pools for solvency, but they
    ///      remain individually attributed, so a later distribution can pay the right LPs.
    function test_potsAreAttributedPerPoolDespiteSharingACurrency() public {
        (bytes32[] memory idsA,) = _buildTwoPoolState();

        uint256 potABefore = hook.insurancePot(idA, usdcCurrency);
        uint256 potBBefore = hook.insurancePot(idB, usdcCurrency);

        // Settle another pool-A bond only.
        _settleAll(idsA);

        assertGt(hook.insurancePot(idA, usdcCurrency), potABefore, "pool A's pot did not grow");
        assertEq(hook.insurancePot(idB, usdcCurrency), potBBefore, "settling in pool A moved pool B's pot");
    }

    /// @notice The other currencies stay separate: a USDC slash never credits tokenX or tokenY.
    function test_nonSharedCurrenciesAreUnaffected() public {
        _buildTwoPoolState();

        assertEq(hook.insurancePot(idA, Currency.wrap(address(tokenX))), 0, "a USDC slash credited tokenX in pool A");
        assertEq(hook.insurancePot(idB, Currency.wrap(address(tokenY))), 0, "a USDC slash credited tokenY in pool B");
    }

    /*//////////////////////////////////////////////////////////////
                            SCENARIO BUILDER
    //////////////////////////////////////////////////////////////*/

    /// @dev Opens two USDC-denominated bonds in each pool, crosses both maturities, and settles
    ///      exactly one bond per pool. The result carries all four liability components at once.
    function _buildTwoPoolState() internal returns (bytes32[] memory idsA, bytes32[] memory idsB) {
        uint32 m = _maturityOfNow();

        idsA = new bytes32[](2);
        idsB = new bytes32[](2);

        for (uint32 i = 0; i < 2; i++) {
            idsA[i] = _bondId(idA, m, i);
            _swapSpendingUsdc(keyA, usdcIsZeroInA, BONDED, TRADER_A);

            idsB[i] = _bondId(idB, m, i);
            _swapSpendingUsdc(keyB, usdcIsZeroInB, BONDED, TRADER_B);
        }

        // NON-VACUITY. Both pools' bonds must genuinely be denominated in the SAME physical
        // ERC-20, or every aggregation assertion downstream is satisfied for the wrong reason.
        _assertAllCollateralIsUsdc(idsA, usdcIsZeroInA, "pool A");
        _assertAllCollateralIsUsdc(idsB, usdcIsZeroInB, "pool B");

        // Cross both maturities so the checkpoints freeze in both pools.
        vm.roll(uint256(m) + 1);
        _nudge(keyA, usdcIsZeroInA);
        _nudge(keyB, usdcIsZeroInB);

        // Settle one bond in each pool: creates a pot on both sides while leaving one live
        // liability on both sides.
        hook.settleBond(idsA[0]);
        hook.settleBond(idsB[0]);
    }

    /// @dev Settles every still-unsettled bond in the list.
    function _settleAll(bytes32[] memory ids) internal {
        for (uint256 i = 0; i < ids.length; i++) {
            if (uint8(hook.getBond(ids[i]).state) == 2) {
                hook.settleBond(ids[i]);
            }
        }
    }
}
