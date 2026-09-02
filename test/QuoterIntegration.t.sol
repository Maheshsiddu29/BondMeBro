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
import {ModelLReference} from "./utils/ModelLReference.sol";

/// @title QuoterIntegrationTest
///
/// @notice What the REAL `V4Quoter` reports for a BondMeBro pool, and how a caller must set
///         slippage against it now that collateral comes out of the variable leg.
///
/// @dev WHY THIS SUITE EXISTS, AND WHY IT IS NOT OPTIONAL AFTER P-L2-3/4.
///
///      A quoter is how integrators size `amountOutMinimum` and `amountInMaximum`. Before this
///      stage the hook carved its collateral out of the INPUT, so an exact-input quote described
///      the output faithfully and only the input side needed adjusting. Under variable-leg custody
///      the collateral comes off the OUTPUT for exact-input swaps -- which is precisely the number
///      `amountOutMinimum` is set against.
///
///      So the question this file answers is a practical one an integrator will hit on day one:
///      DOES THE QUOTE ALREADY ACCOUNT FOR THE BOND, OR NOT? Getting that wrong in either
///      direction is a live failure: too tight and every swap reverts on slippage; too loose and
///      the protection is not doing its job.
///
///      `V4Quoter` executes the swap for real inside a reverting simulation, hooks included, so
///      the answer is determined by what the hook actually does rather than by anything the quoter
///      chooses. These tests establish it by measurement and then pin it, so a future change to
///      custody that silently alters the relationship fails here rather than in production.
contract QuoterIntegrationTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    BondMeBro internal hook;
    V4Quoter internal quoter;
    MockV4Router internal router;

    PoolKey internal key_;
    PoolId internal id_;

    address internal constant TRADER = address(0xB0B);

    uint128 internal constant MIN_BONDED = 1e15;
    uint96 internal constant MIN_BONDED_1 = 1e15;
    uint16 internal constant BOND_BPS = 25;
    uint16 internal constant REFUND_TOL = 5;

    uint128 internal constant GENEROUS_CEILING = type(uint128).max;

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

        hook.setPoolConfig(key_, MIN_BONDED, MIN_BONDED_1, BOND_BPS, REFUND_TOL);

        quoter = new V4Quoter(manager);

        router = new MockV4Router(manager);

        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _hookData() internal pure returns (bytes memory) {
        return HookDataCodec.encode(TRADER, GENEROUS_CEILING);
    }

    function _quoteExactIn(uint128 amountIn, bool zeroForOne) internal returns (uint256 amountOut) {
        (amountOut,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key_, zeroForOne: zeroForOne, exactAmount: amountIn, hookData: _hookData()
            })
        );
    }

    function _quoteExactOut(uint128 amountOut, bool zeroForOne) internal returns (uint256 amountIn) {
        (amountIn,) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key_, zeroForOne: zeroForOne, exactAmount: amountOut, hookData: _hookData()
            })
        );
    }

    function _routerExactIn(uint128 amountIn, uint128 amountOutMinimum, bool zeroForOne) internal {
        (Currency inputCurrency, Currency outputCurrency) = zeroForOne ? (currency0, currency1) : (currency1, currency0);

        Plan memory plan = Planner.init();

        plan = plan.add(
            Actions.SWAP_EXACT_IN_SINGLE,
            abi.encode(
                IV4Router.ExactInputSingleParams({
                    poolKey: key_,
                    zeroForOne: zeroForOne,
                    amountIn: amountIn,
                    amountOutMinimum: amountOutMinimum,
                    minHopPriceX36: 0,
                    hookData: _hookData()
                })
            )
        );

        router.executeActions(plan.finalizeSwap(inputCurrency, outputCurrency, ActionConstants.MSG_SENDER));
    }

    function _routerExactOut(uint128 amountOut, uint128 amountInMaximum, bool zeroForOne) internal {
        (Currency inputCurrency, Currency outputCurrency) = zeroForOne ? (currency0, currency1) : (currency1, currency0);

        Plan memory plan = Planner.init();

        plan = plan.add(
            Actions.SWAP_EXACT_OUT_SINGLE,
            abi.encode(
                IV4Router.ExactOutputSingleParams({
                    poolKey: key_,
                    zeroForOne: zeroForOne,
                    amountOut: amountOut,
                    amountInMaximum: amountInMaximum,
                    minHopPriceX36: 0,
                    hookData: _hookData()
                })
            )
        );

        router.executeActions(plan.finalizeSwap(inputCurrency, outputCurrency, ActionConstants.MSG_SENDER));
    }

    /*//////////////////////////////////////////////////////////////
                      EXACT-INPUT: QUOTE vs REALITY
    //////////////////////////////////////////////////////////////*/

    /// @notice The exact-input quote is NET of the bond: it equals what the trader actually
    ///         receives, not the pool's raw output.
    ///
    /// @dev THE ANSWER TO THE QUESTION THIS FILE OPENS WITH, established by measurement.
    ///
    ///      `V4Quoter` runs the swap for real inside a reverting simulation and reads the
    ///      caller-side delta. `PoolManager` applies `hookDeltaUnspecified` to that delta before
    ///      returning it, so the hook's claim is already deducted by the time the quoter sees it.
    ///      The quote therefore describes the trader's receipt, which is exactly the quantity
    ///      `amountOutMinimum` is compared against.
    ///
    ///      That is the convenient answer, and it is worth pinning precisely because it is
    ///      convenient: integrators will rely on it implicitly. If custody ever moved to a
    ///      mechanism the quoter cannot see, every one of those integrations would start quoting
    ///      too high with no error anywhere -- and this test is what would catch it.
    ///
    ///      Both directions are checked, because the collateral currency differs between them.
    function test_exactInput_quoteIsNetOfTheBond() public {
        for (uint256 i = 0; i < 2; i++) {
            bool zeroForOne = i == 0;

            uint256 snapshot = vm.snapshotState();

            uint256 quoted = _quoteExactIn(SWAP_SIZE, zeroForOne);

            // For exact-input the collateral is the OUTPUT currency.
            Currency outputCurrency = zeroForOne ? currency1 : currency0;

            uint256 traderBefore = outputCurrency.balanceOf(address(this));
            uint256 hookBefore = outputCurrency.balanceOf(address(hook));

            swapRouter.swap(
                key_,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(uint256(SWAP_SIZE)),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                _hookData()
            );

            uint256 received = outputCurrency.balanceOf(address(this)) - traderBefore;
            uint256 bond = outputCurrency.balanceOf(address(hook)) - hookBefore;

            assertGt(bond, 0, "the fixture did not bond; the quote relationship would be trivial");

            // THE PIN. The quote is what the trader receives, bond already deducted.
            assertEq(quoted, received, "the exact-input quote does not equal the trader's actual receipt");

            // And it is strictly below the pool's RAW output by exactly the bond, which is the
            // statement that the deduction is real rather than a coincidence of this fixture.
            assertEq(received + bond - quoted, bond, "the quote is not short of the raw output by exactly the bond");

            assertLt(quoted, received + bond, "the quote was NOT net of the bond");

            console2.log(zeroForOne ? "zeroForOne quoted" : "oneForZero quoted", quoted);
            console2.log("  bond withheld from the output", bond);

            vm.revertToState(snapshot);
        }
    }

    /// @notice A router slippage bound set from the quote succeeds at exactly the quote, and fails
    ///         one wei above it.
    ///
    /// @dev The practical consequence of the test above, proven at the boundary rather than
    ///      asserted in prose. `amountOutMinimum == quote` must pass -- if it did not, no
    ///      integrator could ever use the quoter without padding it by an unknown amount -- and
    ///      `quote + 1` must fail, which is what shows the bound is actually being enforced
    ///      against the post-bond figure rather than against something slacker.
    function test_exactInput_slippageBoundFromQuoteIsExactlyAchievable() public {
        uint256 probe = vm.snapshotState();

        uint256 quoted = _quoteExactIn(SWAP_SIZE, true);

        vm.revertToState(probe);

        // Exactly at the quote: must succeed.
        uint256 traderBefore = currency1.balanceOf(address(this));

        _routerExactIn(SWAP_SIZE, uint128(quoted), true);

        assertEq(
            currency1.balanceOf(address(this)) - traderBefore,
            quoted,
            "a slippage bound equal to the quote did not deliver exactly the quote"
        );

        vm.revertToState(probe);

        // One wei above the quote: must fail. The bond is what makes the difference, so this is
        // also the assertion that the hook's claim is inside the protected quantity.
        vm.expectRevert();

        _routerExactIn(SWAP_SIZE, uint128(quoted + 1), true);
    }

    /// @notice An integrator who sets slippage from a PRE-BOND output figure is protected: the
    ///         swap reverts rather than silently delivering less.
    ///
    /// @dev The failure mode this suite exists to characterise. Someone who computes the expected
    ///      output from the pool's own math -- ignoring the hook -- and passes that as
    ///      `amountOutMinimum` is asking for more than the swap can deliver. The important
    ///      property is that this FAILS CLOSED: they get a revert, not a quiet shortfall.
    function test_exactInput_preBondSlippageBoundRevertsRatherThanShortChanging() public {
        uint256 probe = vm.snapshotState();

        uint256 quoted = _quoteExactIn(SWAP_SIZE, true);

        // Reconstruct the raw, pre-bond output the pool would have paid.
        uint256 hookBefore = currency1.balanceOf(address(hook));

        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(SWAP_SIZE)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _hookData()
        );

        uint256 rawOutput = quoted + (currency1.balanceOf(address(hook)) - hookBefore);

        vm.revertToState(probe);

        assertGt(rawOutput, quoted, "the fixture produced no bond, so there is no pre-bond figure to test");

        vm.expectRevert();

        _routerExactIn(SWAP_SIZE, uint128(rawOutput), true);
    }

    /*//////////////////////////////////////////////////////////////
                     EXACT-OUTPUT: QUOTE vs REALITY
    //////////////////////////////////////////////////////////////*/

    /// @notice The exact-output quote is INCLUSIVE of the bond: it equals the trader's total
    ///         input, pool input plus collateral.
    ///
    /// @dev The mirror of the exact-input case, and it lands the same way for the same structural
    ///      reason: the quoter reads the caller-side delta after `PoolManager` has applied the
    ///      hook's claim, and for exact-output that claim is an additional DEBIT in the input
    ///      currency. So the quote is the all-in cost, which is the quantity `amountInMaximum` is
    ///      compared against.
    ///
    ///      Unlike exact-input, this relationship is unchanged by P-L2-3/4 -- exact-output
    ///      collateral came from the input before and still does. It is pinned anyway, because the
    ///      unified custody path now computes both kinds through the same code, so a defect in
    ///      that path could move either one.
    function test_exactOutput_quoteIncludesTheBond() public {
        for (uint256 i = 0; i < 2; i++) {
            bool zeroForOne = i == 0;

            uint256 snapshot = vm.snapshotState();

            uint256 quoted = _quoteExactOut(SWAP_SIZE, zeroForOne);

            // For exact-output the collateral is the INPUT currency.
            Currency inputCurrency = zeroForOne ? currency0 : currency1;
            Currency outputCurrency = zeroForOne ? currency1 : currency0;

            uint256 traderInBefore = inputCurrency.balanceOf(address(this));
            uint256 traderOutBefore = outputCurrency.balanceOf(address(this));
            uint256 hookBefore = inputCurrency.balanceOf(address(hook));
            uint256 mgrBefore = inputCurrency.balanceOf(address(manager));

            swapRouter.swap(
                key_,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: int256(uint256(SWAP_SIZE)),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                _hookData()
            );

            uint256 spent = traderInBefore - inputCurrency.balanceOf(address(this));
            uint256 bond = inputCurrency.balanceOf(address(hook)) - hookBefore;
            uint256 poolInput = inputCurrency.balanceOf(address(manager)) - mgrBefore;

            assertGt(bond, 0, "the fixture did not bond");

            assertEq(
                outputCurrency.balanceOf(address(this)) - traderOutBefore,
                SWAP_SIZE,
                "the trader did not receive exactly the requested output"
            );

            // THE PIN. The quote is the trader's all-in input.
            assertEq(quoted, spent, "the exact-output quote does not equal the trader's actual spend");

            assertEq(quoted, poolInput + bond, "the quote is not poolInput + bond");

            assertGt(quoted, poolInput, "the quote does NOT include the bond");

            console2.log(zeroForOne ? "zeroForOne quoted-in" : "oneForZero quoted-in", quoted);
            console2.log("  of which bond", bond);

            vm.revertToState(snapshot);
        }
    }

    /// @notice `amountInMaximum` set from the quote succeeds exactly, and fails one wei below.
    function test_exactOutput_maxInputFromQuoteIsExactlyAchievable() public {
        uint256 probe = vm.snapshotState();

        uint256 quoted = _quoteExactOut(SWAP_SIZE, true);

        vm.revertToState(probe);

        uint256 traderBefore = currency0.balanceOf(address(this));

        _routerExactOut(SWAP_SIZE, uint128(quoted), true);

        assertEq(
            traderBefore - currency0.balanceOf(address(this)),
            quoted,
            "a maximum equal to the quote did not spend exactly the quote"
        );

        vm.revertToState(probe);

        vm.expectRevert();

        _routerExactOut(SWAP_SIZE, uint128(quoted - 1), true);
    }

    /*//////////////////////////////////////////////////////////////
                       THE QUOTE IS NOT A PROMISE
    //////////////////////////////////////////////////////////////*/

    /// @notice A quote taken before an intervening swap no longer holds -- and the trader's
    ///         protection is `maxBondAmount`, not the quote.
    ///
    /// @dev THE HONEST LIMIT OF EVERYTHING ABOVE, and it is sharper under Model L than it was.
    ///
    ///      The collateral now depends on the tick impact the swap turns out to have, which
    ///      depends on the pool's state when it executes. So a quote is a measurement of a
    ///      hypothetical present, not a commitment about the future, and the gap between quoting
    ///      and executing is not bounded by anything the hook controls.
    ///
    ///      This is not a defect and there is no fix that belongs in the hook -- it is the same
    ///      property every AMM quote has. What matters is that the trader has an independent
    ///      instrument for the part they care about: `maxBondAmount` caps the COLLATERAL directly,
    ///      denominated in the collateral currency (hookData v2), and is enforced regardless of
    ///      what the pool did in between. This test shows the quote drifting and the ceiling still
    ///      holding.
    function test_quoteIsNotAPromise_butTheCeilingStillBinds() public {
        uint256 quotedBefore = _quoteExactIn(SWAP_SIZE, true);

        // Someone else moves the price substantially.
        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(2e17)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _hookData()
        );

        uint256 quotedAfter = _quoteExactIn(SWAP_SIZE, true);

        assertLt(
            quotedAfter, quotedBefore, "the intervening swap did not move the quote; the test is not exercising drift"
        );

        // The trader's ceiling is denominated in the COLLATERAL currency and is enforced on the
        // collateral itself, so it binds no matter what the pool did in between. A ceiling of 1 is
        // below any bond this pool can produce.
        uint256 hookBefore = currency1.balanceOf(address(hook));

        vm.expectRevert();

        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(SWAP_SIZE)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            HookDataCodec.encode(TRADER, 1)
        );

        assertEq(currency1.balanceOf(address(hook)), hookBefore, "a rejected swap still moved collateral");
    }

    /// @notice The quoter agrees with the independent Model L reference on the bond it implies.
    ///
    /// @dev Ties the two halves together: the difference between the pool's raw output and the
    ///      quoted output must be exactly the collateral `ModelLReference` predicts for the
    ///      realized leg and impact. If the quote and the hook ever disagreed about the bond, this
    ///      is where it would show, in the currency an integrator actually cares about.
    function testFuzz_quoteImpliesTheModelLBond(uint96 rawSize) public {
        uint128 size = uint128(bound(uint256(rawSize), uint256(MIN_BONDED), 2e17));

        uint256 probe = vm.snapshotState();

        uint256 quoted = _quoteExactIn(size, true);

        vm.revertToState(probe);

        // slither-disable-next-line unused-return
        (, int24 tickBefore,,) = manager.getSlot0(id_);

        uint256 hookBefore = currency1.balanceOf(address(hook));
        uint256 traderBefore = currency1.balanceOf(address(this));

        swapRouter.swap(
            key_,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(size)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            _hookData()
        );

        // slither-disable-next-line unused-return
        (, int24 tickAfter,,) = manager.getSlot0(id_);

        uint256 bond = currency1.balanceOf(address(hook)) - hookBefore;
        uint256 received = currency1.balanceOf(address(this)) - traderBefore;

        assertEq(quoted, received, "the quote and the realized receipt diverged");

        assertEq(
            bond,
            ModelLReference.collateralFor(received + bond, tickBefore, tickAfter),
            "the bond implied by the quote is not the Model L collateral"
        );
    }
}
