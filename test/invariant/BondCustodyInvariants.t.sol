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
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {BondMeBro, HOOK_FLAGS} from "../../src/BondMeBro.sol";
import {BondCustodyHandler} from "./BondCustodyHandler.sol";

/// @title BondCustodyInvariantsTest

/// @notice Stateful invariant tests for BondMeBro's current bond-custody implementation.

/// @dev Unit tests verify individual swaps. These invariants verify that custody remains correct across sequences of exact-input and exact-output swaps, both directions, including reverted transactions.

/// T3/T3B/T3C only implement custody. Bonds cannot yet be settled or refunded, so every bond ever taken should still be physically held by the hook. T5 will introduce bond records and outflows, so these accounting invariants must be updated when settlement is implemented.

/// Maturity and settlement invariants are intentionally not tested here because maturity checkpoints do not exist yet. T5 must add tests proving that the settlement result is fixed at maturity and cannot be changed by later swaps.

contract BondCustodyInvariantsTest is Test, Deployers {
    BondMeBro internal hook;
    BondCustodyHandler internal handler;

    PoolKey internal key_;
    PoolId internal id_;

    uint128 internal constant MIN_BONDED = 1e15;
    uint96 internal constant MIN_BONDED_1 = 1e15;
    uint16 internal constant BOND_BPS = 25;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (address predicted, bytes32 salt) =
            HookMiner.find(
                address(this),
                HOOK_FLAGS,
                type(BondMeBro).creationCode,
                abi.encode(
                    manager,
                    address(this)
                )
            );

        hook =
            new BondMeBro{salt: salt}(
                IPoolManager(address(manager)),
                address(this)
            );

        assertEq(
            address(hook),
            predicted,
            "mined address mismatch"
        );

        (key_, id_) =
            initPoolAndAddLiquidity(
                currency0,
                currency1,
                IHooks(address(hook)),
                3000,
                TickMath.getSqrtPriceAtTick(0)
            );

        // Add deep liquidity so the invariant campaign spends most calls testing
        // custody rather than reverting because the liquidity range is exhausted.
        modifyLiquidityRouter.modifyLiquidity(
            key_,
            ModifyLiquidityParams({
                tickLower: -60_000,
                tickUpper: 60_000,
                liquidityDelta: 1e23,
                salt: bytes32(uint256(1))
            }),
            ""
        );

        hook.setPoolConfig(
            key_,
            MIN_BONDED,
            MIN_BONDED_1,
            BOND_BPS
        );

        handler =
            new BondCustodyHandler(
                IPoolManager(address(manager)),
                swapRouter,
                hook,
                key_,
                currency0,
                currency1
            );

        // Fund the handler with both currencies and allow the test router to
        // pull tokens during swaps.
        MockERC20(Currency.unwrap(currency0))
            .mint(address(handler), 1e30);

        MockERC20(Currency.unwrap(currency1))
            .mint(address(handler), 1e30);

        vm.startPrank(address(handler));

        MockERC20(Currency.unwrap(currency0))
            .approve(
                address(swapRouter),
                type(uint256).max
            );

        MockERC20(Currency.unwrap(currency1))
            .approve(
                address(swapRouter),
                type(uint256).max
            );

        vm.stopPrank();

        // Restrict the stateful campaign to the handler's two swap actions.
        bytes4[] memory selectors =
            new bytes4[](2);

        selectors[0] =
            BondCustodyHandler.swapExactInput.selector;

        selectors[1] =
            BondCustodyHandler.swapExactOutput.selector;

        targetSelector(
            FuzzSelector({
                addr: address(handler),
                selectors: selectors
            })
        );

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The hook's real token balance must equal the total bonds it actually received.

    /// @dev This is checked separately for currency0 and currency1 because every bond must remain denominated in the swap's input currency. In the current custody-only build nothing can leave the hook, so the relationship should be exact.
    function invariant_hookBalanceEqualsSumOfBondsTaken()
        public
        view
    {
        assertEq(
            currency0.balanceOf(address(hook)),
            handler.measuredBondTotal(currency0),
            "currency0: hook balance != sum of bonds taken"
        );

        assertEq(
            currency1.balanceOf(address(hook)),
            handler.measuredBondTotal(currency1),
            "currency1: hook balance != sum of bonds taken"
        );
    }

    /// @notice Every bond actually received by the hook must match the amount independently predicted by the bond formulas.

    /// @dev The handler calculates expected custody separately from the hook's token balance:
    ///
    /// Exact-input:
    /// `bond = grossInput * bondBps / 10_000`
    ///
    /// Exact-output:
    /// `bond = poolInput * bondBps / (10_000 - bondBps)`
    ///
    /// If the hook takes a different amount on either path, this invariant fails.
    function invariant_bondsMatchTheFormula()
        public
        view
    {
        assertEq(
            handler.measuredBondTotal(currency0),
            handler.expectedBondTotal(currency0),
            "currency0: bonds taken != bonds the formula predicts"
        );

        assertEq(
            handler.measuredBondTotal(currency1),
            handler.expectedBondTotal(currency1),
            "currency1: bonds taken != bonds the formula predicts"
        );
    }

    /// @notice The hook must not hold PoolManager claim tokens after a completed swap.

    /// @dev BondMeBro uses physical token custody with `claims = false`. A non-zero ERC-6909 claim balance would mean some custody was represented as a claim against PoolManager instead of real ERC-20 tokens held by the hook.
    function invariant_hookHoldsNoPoolManagerClaims()
        public
        view
    {
        assertEq(
            manager.balanceOf(
                address(hook),
                currency0.toId()
            ),
            0,
            "hook holds currency0 claims"
        );

        assertEq(
            manager.balanceOf(
                address(hook),
                currency1.toId()
            ),
            0,
            "hook holds currency1 claims"
        );
    }

    /// @notice Every expected bond must be backed by real tokens held by the hook.

    /// @dev In the current custody-only build, no refund or settlement path can remove tokens, so the hook must always hold at least the collateral represented by the expected bond totals. T5 must replace this simple custody rule with settlement-aware liability accounting.
    function invariant_hookIsFullyBackedByRealTokens()
        public
        view
    {
        assertGe(
            currency0.balanceOf(address(hook)),
            handler.expectedBondTotal(currency0),
            "currency0: bonds not backed"
        );

        assertGe(
            currency1.balanceOf(address(hook)),
            handler.expectedBondTotal(currency1),
            "currency1: bonds not backed"
        );
    }

    /*//////////////////////////////////////////////////////////////
                         CAMPAIGN COVERAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Prints how many times each custody path was exercised during the invariant campaign.

    /// @dev Reporting only. Path reachability is tested separately by `test_handlerExercisesAllFourCustodyPaths` so invariant shrinking cannot turn a coverage assertion into an unrelated failure.
    function afterInvariant() public view {
        console2.log(
            "exact-input  bonded  :",
            handler.exactInputBonded()
        );

        console2.log(
            "exact-input  unbonded:",
            handler.exactInputUnbonded()
        );

        console2.log(
            "exact-output bonded  :",
            handler.exactOutputBonded()
        );

        console2.log(
            "exact-output unbonded:",
            handler.exactOutputUnbonded()
        );

        console2.log(
            "reverted             :",
            handler.reverted()
        );
    }

    /// @notice Proves that the handler can reach all four custody paths.

    /// @dev This prevents a vacuous invariant campaign where every action reverts or does nothing and all accounting totals remain zero. The hand-picked seeds deterministically exercise bonded and unbonded exact-input and exact-output swaps.
    function test_handlerExercisesAllFourCustodyPaths()
        public
    {
        // Odd seed => amount at or above threshold => bonded exact-input.
        handler.swapExactInput(
            3,
            true,
            false
        );

        assertEq(
            handler.exactInputBonded(),
            1,
            "exact-input bonded path unreachable"
        );

        // Even seed => amount below threshold => unbonded exact-input.
        handler.swapExactInput(
            2,
            true,
            false
        );

        assertEq(
            handler.exactInputUnbonded(),
            1,
            "exact-input unbonded path unreachable"
        );

        // Exact-output, opposite direction, bonded.
        handler.swapExactOutput(
            3,
            false,
            false
        );

        assertEq(
            handler.exactOutputBonded(),
            1,
            "exact-output bonded path unreachable"
        );

        // Exact-output, opposite direction, unbonded.
        handler.swapExactOutput(
            2,
            false,
            false
        );

        assertEq(
            handler.exactOutputUnbonded(),
            1,
            "exact-output unbonded path unreachable"
        );

        // Confirm that both input currencies were actually taken as collateral.
        assertGt(
            handler.measuredBondTotal(currency0),
            0,
            "no currency0 bond was actually taken"
        );

        assertGt(
            handler.measuredBondTotal(currency1),
            0,
            "no currency1 bond was actually taken"
        );

        // Ghost accounting must match the hook's real ERC-20 balances.
        assertEq(
            currency0.balanceOf(address(hook)),
            handler.measuredBondTotal(currency0),
            "currency0 ghost disagrees with the hook's real balance"
        );

        assertEq(
            currency1.balanceOf(address(hook)),
            handler.measuredBondTotal(currency1),
            "currency1 ghost disagrees with the hook's real balance"
        );
    }

    /// @notice A reverted swap must not change the hook's custody accounting.

    /// @dev The handler's `tightCeiling` mode sets `maxBondAmount` one wei below the required bond, forcing the hook to revert. The hook balance and ghost accounting must remain unchanged.
    function test_rejectedSwapLeavesAccountingUntouched()
        public
    {
        // First create a successful bond so we have a non-zero baseline.
        handler.swapExactInput(
            3,
            true,
            false
        );

        uint256 hookBalance =
            currency0.balanceOf(address(hook));

        uint256 ghost =
            handler.measuredBondTotal(currency0);

        assertGt(
            hookBalance,
            0,
            "baseline bond was not taken"
        );

        // Repeat with a bond ceiling one wei below the required amount.
        handler.swapExactInput(
            3,
            true,
            true
        );

        assertEq(
            handler.reverted(),
            1,
            "the tight-ceiling swap did not revert"
        );

        assertEq(
            currency0.balanceOf(address(hook)),
            hookBalance,
            "a reverted swap changed the hook balance"
        );

        assertEq(
            handler.measuredBondTotal(currency0),
            ghost,
            "a reverted swap moved the ghost"
        );
    }
}