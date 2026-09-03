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

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {MockV4Router} from "@uniswap/v4-periphery/test/mocks/MockV4Router.sol";
import {Plan, Planner} from "@uniswap/v4-periphery/test/shared/Planner.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";

import {BondMeBro, HOOK_FLAGS} from "../src/BondMeBro.sol";
import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";

/// @title BlockImpactQuoterPolicyTest
///
/// @notice ADR-0008 § 8. The frontend policy for `maxBondAmount`, `amountOutMinimum` and
///         `amountInMaximum` under a collateral rate that depends on block ordering.
///
/// @dev THE PROBLEM, PRECISELY. `maxBondAmount` is an ABSOLUTE raw amount in the collateral
///      currency, checked as `bond > maxBondAmount -> revert`, where
///      `bond = variableLegAmount * collateralBps / BPS`. Since ADR-0008 BOTH factors are unknown
///      at quote time: `collateralBps` depends on `blockStartTick`, i.e. on transaction ORDERING,
///      and `variableLegAmount` depends on execution, which ordering also moves.
///
///      "Use the 1% cap" is not by itself an answer, because the cap bounds a RATE and
///      `maxBondAmount` is an AMOUNT. The rate still has to be multiplied by a leg the frontend
///      does not know. This file derives the answer for each swap kind and drives it through the
///      REAL `V4Quoter` and `MockV4Router`.
///
///      THE TWO KINDS ARE NOT SYMMETRIC, and that asymmetry is the whole resolution:
///
///        EXACT INPUT  — collateral comes OUT OF the output, so `receipt = output * (1 - bps/BPS)`
///                       is INCREASING in output and `amountOutMinimum` — denominated in that same
///                       currency, compared against that same receipt — is already a complete
///                       bound on the trader's loss.
///
///        EXACT OUTPUT — collateral is ADDED ON TOP of the input, so a bound is genuinely needed
///                       and `amountInMaximum` supplies it.
contract BlockImpactQuoterPolicyTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    BondMeBro internal hook;
    V4Quoter internal quoter;
    MockV4Router internal router;

    PoolKey internal key_;
    PoolId internal id_;

    address internal constant TRADER = address(0xB0B);

    uint128 internal constant MIN_BONDED = 1e15;
    uint96 internal constant MIN_BONDED_1 = 1e15;
    int128 internal constant POOL_LIQUIDITY = 1e19;
    uint128 internal constant SWAP_SIZE = 1e16;

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

        quoter = new V4Quoter(manager);
        router = new MockV4Router(manager);

        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _hookData(uint128 ceiling) internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, ceiling);
    }

    function _tick() internal view returns (int24 t) {
        // slither-disable-next-line unused-return
        (, t,,) = manager.getSlot0(id_);
    }

    function _quoteExactIn(uint128 amountIn, bool zeroForOne) internal returns (uint256 amountOut) {
        (amountOut,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key_, zeroForOne: zeroForOne, exactAmount: amountIn, hookData: _hookData(type(uint128).max)
            })
        );
    }

    function _quoteExactOut(uint128 amountOut, bool zeroForOne) internal returns (uint256 amountIn) {
        (amountIn,) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key_, zeroForOne: zeroForOne, exactAmount: amountOut, hookData: _hookData(type(uint128).max)
            })
        );
    }

    function _routerExactIn(uint128 amountIn, uint128 minOut, uint128 ceiling, bool zeroForOne) internal {
        (Currency inC, Currency outC) = zeroForOne ? (currency0, currency1) : (currency1, currency0);

        Plan memory plan = Planner.init();

        plan = plan.add(
            Actions.SWAP_EXACT_IN_SINGLE,
            abi.encode(
                IV4Router.ExactInputSingleParams({
                    poolKey: key_,
                    zeroForOne: zeroForOne,
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    minHopPriceX36: 0,
                    hookData: _hookData(ceiling)
                })
            )
        );

        router.executeActions(plan.finalizeSwap(inC, outC, ActionConstants.MSG_SENDER));
    }

    function _routerExactOut(uint128 amountOut, uint128 maxIn, uint128 ceiling, bool zeroForOne) internal {
        (Currency inC, Currency outC) = zeroForOne ? (currency0, currency1) : (currency1, currency0);

        Plan memory plan = Planner.init();

        plan = plan.add(
            Actions.SWAP_EXACT_OUT_SINGLE,
            abi.encode(
                IV4Router.ExactOutputSingleParams({
                    poolKey: key_,
                    zeroForOne: zeroForOne,
                    amountOut: amountOut,
                    amountInMaximum: maxIn,
                    minHopPriceX36: 0,
                    hookData: _hookData(ceiling)
                })
            )
        );

        router.executeActions(plan.finalizeSwap(inC, outC, ActionConstants.MSG_SENDER));
    }

    /// @dev Self-calls so a revert can be caught rather than aborting the test.
    function externalRouterExactIn(uint128 amountIn, uint128 minOut, uint128 ceiling, bool zeroForOne) external {
        require(msg.sender == address(this), "self only");

        _routerExactIn(amountIn, minOut, ceiling, zeroForOne);
    }

    function externalRouterExactOut(uint128 amountOut, uint128 maxIn, uint128 ceiling, bool zeroForOne) external {
        require(msg.sender == address(this), "self only");

        _routerExactOut(amountOut, maxIn, ceiling, zeroForOne);
    }

    /// @dev Displaces the current block by roughly `ticks`, trading AGAINST our direction.
    ///
    ///      OPPOSITE DIRECTION ON PURPOSE. A same-direction front-run would worsen our price as
    ///      well as displacing the block, and the two effects would be inseparable. Trading against
    ///      us improves our fill while still displacing the block, which isolates the collateral
    ///      term — the thing under test.
    function _displaceBlock(int24 ticks) internal {
        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(uint256(type(uint96).max)),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(_tick() + ticks)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _hookData(type(uint128).max)
        );
    }

    /*//////////////////////////////////////////////////////////////
                  s 14 -- THE QUOTER PINS, RE-ASSERTED
    //////////////////////////////////////////////////////////////*/

    /// @notice The exact-input quote is still NET of the bond after the migration.
    ///
    /// @dev `QuoterIntegration.t.sol` pins this pre-migration; it is re-asserted here because the
    ///      ENTIRE exact-input frontend policy rests on it. `PoolManager` applies
    ///      `hookDeltaUnspecified` to the caller-side delta before the quoter reads it, so the
    ///      quote already describes the trader's receipt — which is exactly the quantity
    ///      `amountOutMinimum` is compared against.
    function test_s14_exactInputQuoteIsStillNetOfTheBond() public {
        for (uint256 i = 0; i < 2; i++) {
            bool zeroForOne = i == 0;

            uint256 snap = vm.snapshotState();

            uint256 quoted = _quoteExactIn(SWAP_SIZE, zeroForOne);

            Currency outC = zeroForOne ? currency1 : currency0;

            uint256 before = outC.balanceOf(address(this));

            swapRouter.swap(
                key_,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(uint256(SWAP_SIZE)),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                _hookData(type(uint128).max)
            );

            assertEq(outC.balanceOf(address(this)) - before, quoted, "the EI quote is not the trader's net receipt");

            vm.revertToState(snap);
        }
    }

    /// @notice The exact-output quote still INCLUDES the bond.
    function test_s14_exactOutputQuoteStillIncludesTheBond() public {
        for (uint256 i = 0; i < 2; i++) {
            bool zeroForOne = i == 0;

            uint256 snap = vm.snapshotState();

            uint256 quoted = _quoteExactOut(SWAP_SIZE, zeroForOne);

            Currency inC = zeroForOne ? currency0 : currency1;

            uint256 before = inC.balanceOf(address(this));

            swapRouter.swap(
                key_,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: int256(uint256(SWAP_SIZE)),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                _hookData(type(uint128).max)
            );

            assertEq(before - inC.balanceOf(address(this)), quoted, "the EO quote is not the trader's all-in spend");

            vm.revertToState(snap);
        }
    }

    /// @notice HOW STALE A QUOTE BECOMES under block ordering, at each displacement § 14 names.
    ///
    /// @dev The quote is taken in an undisplaced block; execution then lands behind an unrelated
    ///      trade that displaced the block by 25 / 58 / 100 / 500 ticks. Above 397 ticks the rate
    ///      is pinned at the 100 bps cap, which is why the largest row is the interesting one: it
    ///      is the WORST the mechanism can ever do, and it is bounded.
    function test_s14_quoteStalenessAcrossBlockDisplacements() public {
        int24[4] memory displacements = [int24(25), 58, 100, 500];

        uint256 snap = vm.snapshotState();

        uint256 quotedNet = _quoteExactIn(SWAP_SIZE, true);

        vm.revertToState(snap);

        console2.log("QUOTE undisplaced net output", quotedNet);

        for (uint256 i = 0; i < displacements.length; i++) {
            uint256 s2 = vm.snapshotState();

            _displaceBlock(displacements[i]);

            uint256 hookBefore = currency1.balanceOf(address(hook));
            uint256 traderBefore = currency1.balanceOf(address(this));

            swapRouter.swap(
                key_,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(uint256(SWAP_SIZE)),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                _hookData(type(uint128).max)
            );

            uint256 bond = currency1.balanceOf(address(hook)) - hookBefore;
            uint256 received = currency1.balanceOf(address(this)) - traderBefore;

            console2.log("-- block displaced (ticks) ", uint256(int256(displacements[i])));
            console2.log("   realized bond           ", bond);
            console2.log("   realized net receipt    ", received);
            console2.log("   bond as bps of gross    ", (bond * 10_000) / (received + bond));

            // THE PROTOCOL BOUND, and it is what the whole EI policy leans on: whatever the
            // ordering, the hook withholds at most `MAX_BOND_BPS` of the realized gross output.
            assertLe(
                bond * hook.BPS(), (received + bond) * hook.MAX_BOND_BPS(), "the hook withheld more than the rate cap"
            );

            vm.revertToState(s2);
        }
    }

    /*//////////////////////////////////////////////////////////////
                 s 11 -- EXACT-INPUT FRONTEND POLICY
    //////////////////////////////////////////////////////////////*/

    /// @notice THE EI POLICY. `maxBondAmount = type(uint128).max`; `amountOutMinimum` carries the
    ///         protection, derived from the user's own slippage policy plus the rate cap.
    ///
    /// @dev THE RULE, stated so it can be implemented directly:
    ///
    ///          maxBondAmount    = type(uint128).max
    ///          amountOutMinimum = quotedNetOutput * (BPS - userSlippageBps) / BPS
    ///
    ///      NOTE WHAT IS *NOT* SAID: the tolerance does not have to be 1%. The quote is already NET
    ///      of the bond at the block state it was taken in, so a user's ordinary slippage budget is
    ///      the right starting point; what the hook adds is that ordering can withhold up to
    ///      `MAX_BOND_BPS` MORE of the realized output than the quote assumed. A tolerance at or
    ///      above `MAX_BOND_BPS` is therefore guaranteed against the mechanism alone, and any
    ///      tolerance a user would already have accepted for price movement is additive to it.
    ///
    ///      This test uses exactly `MAX_BOND_BPS` as the tolerance — the tightest bound that is
    ///      guaranteed — and shows it surviving displacements up to and past the cap.
    function test_s11_exactInput_amountOutMinimumIsCompleteProtection() public {
        int24[4] memory displacements = [int24(25), 58, 100, 500];

        uint256 snap = vm.snapshotState();

        uint256 quoted = _quoteExactIn(SWAP_SIZE, true);

        vm.revertToState(snap);

        // The tightest guaranteed tolerance: the protocol's own cap, and nothing more.
        uint128 minOut = uint128((quoted * (hook.BPS() - hook.MAX_BOND_BPS())) / hook.BPS());

        console2.log("S11 quoted / amountOutMinimum", quoted, minOut);

        for (uint256 i = 0; i < displacements.length; i++) {
            uint256 s2 = vm.snapshotState();

            _displaceBlock(displacements[i]);

            uint256 before = currency1.balanceOf(address(this));

            _routerExactIn(SWAP_SIZE, minOut, type(uint128).max, true);

            uint256 received = currency1.balanceOf(address(this)) - before;

            console2.log("   displaced / received     ", uint256(int256(displacements[i])), received);

            assertGe(received, minOut, "amountOutMinimum did not bound the net receipt");

            vm.revertToState(s2);
        }
    }

    /// @notice ...and the bound is real, not vacuous: an unachievable minimum reverts.
    function test_s11_exactInput_amountOutMinimumStillBinds() public {
        uint256 snap = vm.snapshotState();

        uint256 quoted = _quoteExactIn(SWAP_SIZE, true);

        vm.revertToState(snap);

        vm.expectRevert();

        _routerExactIn(SWAP_SIZE, uint128(quoted + quoted / 10), type(uint128).max, true);
    }

    /// @notice A ROUTER-LESS caller's rule: `maxBondAmount = legUpperBound * MAX_BOND_BPS / BPS`.
    ///
    /// @dev For a caller with no slippage check of its own, `maxBondAmount` really is the only
    ///      guard, and a QUOTE-DERIVED ceiling is not safe. Both are driven here: the quote-derived
    ///      ceiling is rejected behind a displacement, and the cap-derived one is accepted.
    function test_s11_exactInput_capDerivedCeilingHoldsWhereQuoteDerivedFails() public {
        uint256 snap = vm.snapshotState();

        uint256 quotedOut = _quoteExactIn(SWAP_SIZE, true);

        uint256 hookBefore = currency1.balanceOf(address(hook));

        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(SWAP_SIZE)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _hookData(type(uint128).max)
        );

        uint256 undisplacedBond = currency1.balanceOf(address(hook)) - hookBefore;

        vm.revertToState(snap);

        // A generous multiple of the honest, undisplaced cost.
        uint128 quoteDerived = uint128(undisplacedBond * 4);

        // The rule: a leg allowance the caller is willing to stand behind, times the rate cap.
        uint256 legUpperBound = quotedOut * 2;
        uint128 capDerived = uint128((legUpperBound * hook.MAX_BOND_BPS()) / hook.BPS());

        console2.log("S11 undisplaced bond       ", undisplacedBond);
        console2.log("S11 quote-derived ceiling  ", quoteDerived);
        console2.log("S11 cap-derived ceiling    ", capDerived);

        _displaceBlock(500);

        uint256 s2 = vm.snapshotState();

        _routerExactIn(SWAP_SIZE, 0, capDerived, true);

        console2.log("S11 cap-derived ceiling ACCEPTED");

        vm.revertToState(s2);

        bool quoteDerivedRejected;

        try this.externalRouterExactIn(SWAP_SIZE, 0, quoteDerived, true) {
            quoteDerivedRejected = false;
        } catch {
            quoteDerivedRejected = true;
        }

        console2.log("S11 quote-derived ceiling rejected?", quoteDerivedRejected ? 1 : 0);

        assertTrue(quoteDerivedRejected, "a quote-derived ceiling survived; the documented policy would be wrong");
    }

    /*//////////////////////////////////////////////////////////////
                s 12 -- EXACT-OUTPUT FRONTEND POLICY
    //////////////////////////////////////////////////////////////*/

    /// @dev `amountInMaximum = ceil(P * (BPS + MAX_BOND_BPS) / BPS)`, derived from the constants
    ///      rather than hard-coded, so a future cap change carries it.
    function _amountInMaximumFor(uint256 acceptablePoolInput) internal view returns (uint128) {
        uint256 numerator = acceptablePoolInput * (hook.BPS() + hook.MAX_BOND_BPS());

        // Ceiling division: rounding DOWN here would make the allowance a wei too tight and could
        // reject a swap the rule is meant to admit.
        return uint128((numerator + hook.BPS() - 1) / hook.BPS());
    }

    /// @dev `maxBondAmount = amountInMaximum * MAX_BOND_BPS / (BPS + MAX_BOND_BPS)`.
    ///
    ///      THE DERIVATION, so the "101" in the research note is never hard-coded. With
    ///      `total = poolInput + bond` and `bond = poolInput * bps / BPS`, the two checks bind
    ///      simultaneously when `poolInput = aIM * BPS / (BPS + MAX)`, at which point
    ///      `bond = poolInput * MAX / BPS = aIM * MAX / (BPS + MAX)`. At `BPS = 10_000` and
    ///      `MAX = 100` that is `aIM / 101`.
    ///
    ///      Rounded DOWN deliberately: rounding up would let `maxBondAmount` admit a bond that
    ///      `amountInMaximum` would then reject, which is the ordering this rule exists to avoid.
    function _maxBondFor(uint128 amountInMaximum) internal view returns (uint128) {
        return uint128((uint256(amountInMaximum) * hook.MAX_BOND_BPS()) / (hook.BPS() + hook.MAX_BOND_BPS()));
    }

    /// @notice THE EO POLICY holds at every displacement, including past the cap.
    function test_s12_exactOutput_headroomRuleHolds() public {
        int24[4] memory displacements = [int24(25), 58, 100, 500];

        uint256 snap = vm.snapshotState();

        uint256 quotedTotal = _quoteExactOut(SWAP_SIZE, true);

        vm.revertToState(snap);

        // The trader's own price-slippage budget on POOL input, before any collateral.
        uint256 acceptablePoolInput = (quotedTotal * 105) / 100;

        uint128 maxIn = _amountInMaximumFor(acceptablePoolInput);
        uint128 maxBond = _maxBondFor(maxIn);

        console2.log("S12 quoted total / acceptable P", quotedTotal, acceptablePoolInput);
        console2.log("S12 amountInMaximum / maxBond  ", maxIn, maxBond);

        for (uint256 i = 0; i < displacements.length; i++) {
            uint256 s2 = vm.snapshotState();

            _displaceBlock(displacements[i]);

            uint256 before = currency0.balanceOf(address(this));
            uint256 hookBefore = currency0.balanceOf(address(hook));

            _routerExactOut(SWAP_SIZE, maxIn, maxBond, true);

            uint256 spent = before - currency0.balanceOf(address(this));
            uint256 bond = currency0.balanceOf(address(hook)) - hookBefore;

            console2.log("-- displaced (ticks)       ", uint256(int256(displacements[i])));
            console2.log("   spent / bond            ", spent, bond);
            console2.log("   bond as bps of poolInput", (bond * 10_000) / (spent - bond));

            assertLe(spent, maxIn, "amountInMaximum did not bound total spend");
            assertLe(bond, maxBond, "maxBondAmount was exceeded");

            // THE HEADROOM IS EXACT: the bond can never exceed MAX_BOND_BPS of the pool input.
            assertLe(bond * hook.BPS(), (spent - bond) * hook.MAX_BOND_BPS(), "bond exceeded the cap of pool input");

            vm.revertToState(s2);
        }
    }

    /// @notice `amountInMaximum` binds first or simultaneously — never `maxBondAmount` alone.
    ///
    /// @dev The property that makes the rule usable: the trader gets ONE meaningful failure mode,
    ///      denominated in the quantity they actually care about (total spend), rather than a
    ///      second one on a component they did not choose.
    ///
    ///      Squeezes `amountInMaximum` until the swap fails, then re-runs at the failing point with
    ///      an UNBOUNDED `maxBondAmount`. If it still fails, `amountInMaximum` was the binding
    ///      check and `maxBondAmount` did not fire early.
    function test_s12_exactOutput_maxBondNeverBindsBeforeAmountInMaximum() public {
        uint256 snap = vm.snapshotState();

        uint256 quotedTotal = _quoteExactOut(SWAP_SIZE, true);

        vm.revertToState(snap);

        _displaceBlock(500);

        uint256 firstFailurePct;

        for (uint256 pct = 130; pct >= 80; pct -= 2) {
            uint256 s2 = vm.snapshotState();

            uint128 maxIn = uint128((quotedTotal * pct) / 100);

            try this.externalRouterExactOut(SWAP_SIZE, maxIn, _maxBondFor(maxIn), true) {
                vm.revertToState(s2);
            } catch {
                firstFailurePct = pct;

                vm.revertToState(s2);

                break;
            }
        }

        console2.log("S12 first failing amountInMaximum pct", firstFailurePct);

        assertGt(firstFailurePct, 0, "the squeeze never failed; the test proves nothing");

        uint128 failingMaxIn = uint128((quotedTotal * firstFailurePct) / 100);

        bool failsWithUnboundedBondCeiling;

        try this.externalRouterExactOut(SWAP_SIZE, failingMaxIn, type(uint128).max, true) {
            failsWithUnboundedBondCeiling = false;
        } catch {
            failsWithUnboundedBondCeiling = true;
        }

        console2.log("S12 still fails with unbounded maxBond?", failsWithUnboundedBondCeiling ? 1 : 0);

        assertTrue(
            failsWithUnboundedBondCeiling, "maxBondAmount fired BEFORE amountInMaximum: the derived rule is wrong"
        );
    }

    /// @notice The derived constants really are derived, not the research note's literal 101.
    ///
    /// @dev Guards against someone later replacing the expression with the number. If
    ///      `MAX_BOND_BPS` ever changes, this test changes with it automatically and a hard-coded
    ///      101 would fail here first.
    function test_s12_theHeadroomConstantsAreDerivedFromBpsAndTheCap() public view {
        uint256 p = 1_000_000;

        uint128 maxIn = _amountInMaximumFor(p);

        // At the shipped constants this is P * 1.01 and maxBond is aIM / 101.
        assertEq(uint256(maxIn), (p * (hook.BPS() + hook.MAX_BOND_BPS()) + hook.BPS() - 1) / hook.BPS(), "aIM formula");

        assertEq(
            uint256(_maxBondFor(maxIn)),
            (uint256(maxIn) * hook.MAX_BOND_BPS()) / (hook.BPS() + hook.MAX_BOND_BPS()),
            "maxBond formula"
        );

        // And the pool input the allowance leaves room for really is at least P.
        assertGe((uint256(maxIn) * hook.BPS()) / (hook.BPS() + hook.MAX_BOND_BPS()), p, "the allowance is too tight");
    }
}
