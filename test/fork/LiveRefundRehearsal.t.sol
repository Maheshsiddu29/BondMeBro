// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test, Vm, console2} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {BondMeBro} from "../../src/BondMeBro.sol";
import {IERC20Minimal, IPermit2Minimal, LiveDemo} from "../../script/live-refund-demo/LiveDemo.sol";

/// @title LiveRefundRehearsal
/// @notice Plans and proves ONE price-reversion refund against live Unichain Sepolia state.
///
/// @dev Every persistent-displacement case so far ended in a full slash, which is correct:
/// a price that stays moved is exactly what the collateral is for. To show a refund the
/// pool has to come BACK, and it has to come back before the first observation checkpoint
/// at opening block + 6. An earlier manual attempt reversed at open + 13 and could not
/// have affected the bond at all.
///
/// This rehearsal therefore does two things the manual attempt did not:
///
///   1. It SOLVES for the reverse amount rather than guessing. Fees mean selling back the
///      bWETH you just received undershoots the original tick, so the amount is found by
///      bounded binary search against the live pool.
///   2. It proves the timing, by landing the reverse trade a block or two after the
///      forward and asserting it is inside the C6 window.
///
/// The fork block is explicit and required. Planning against `latest` means planning against
/// whichever state the RPC happened to serve, and that has already produced a zero-liquidity
/// read on a pool holding 2e16.
///
///   UNICHAIN_SEPOLIA_RPC_URL=https://sepolia.unichain.org LIVE_FORK_BLOCK=<block> \
///     forge test --match-path 'test/fork/LiveRefundRehearsal.t.sol' -vv
contract LiveRefundRehearsal is Test {
    using StateLibrary for IPoolManager;

    /// @dev Blocks between the forward and reverse trades, modelling two consecutive
    /// transactions on a one-second chain. C6 is open + 6, so this leaves real headroom.
    uint256 internal constant REVERSE_DELAY_BLOCKS = 2;

    /// @dev Residual we aim for, in ticks. The brief prefers <= 2 and accepts <= 5.
    int24 internal constant TARGET_RESIDUAL = 2;
    int24 internal constant MAX_RESIDUAL = 5;

    /// @dev Allowance headroom granted on the fork so the rehearsal models a PREPARED
    /// wallet. The live run must be prepared separately; approvals must never sit inside
    /// the timed sequence.
    uint256 internal constant PREPARED_ALLOWANCE = 1_000_000e18;

    /// @dev The live BMB-01 demo pool. Asserting this proves the key in `LiveDemo` still
    /// hashes to the pool that actually holds liquidity, rather than to a pool that merely
    /// happens to be readable.
    bytes32 internal constant EXPECTED_POOL_ID = 0xf7c593b94a9389133e5a12e30a199de8947996076d3c97f3080b04dd5fe6f51f;

    /// @dev Liquidity minted at pool deployment. A different value is legitimate if someone
    /// has since added or removed liquidity, so this is reported loudly rather than enforced.
    uint128 internal constant EXPECTED_LIQUIDITY = 20000000000000000;

    /// @dev The block the demo pool was deployed in. Forking before it means the pool does
    /// not exist yet, which is the silent zero-liquidity read this guard exists to prevent.
    uint256 internal constant MIN_FORK_BLOCK = 61620842;

    IPoolManager internal poolManager = IPoolManager(LiveDemo.POOL_MANAGER);
    BondMeBro internal hook = BondMeBro(LiveDemo.HOOK);
    PoolId internal poolId;

    address internal trader = LiveDemo.DEPLOYER;
    address internal settler = makeAddr("unrelated-settler");

    bool internal forked;
    uint256 internal forkBlock;

    function setUp() public {
        string memory rpc = vm.envOr("UNICHAIN_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }

        // An explicit block, never the head. Forking at `latest` races the RPC's own view:
        // the node can serve a state read from a block whose pool state it has not caught up
        // to, which surfaces here as `getLiquidity == 0` on a pool that demonstrably holds
        // 2e16. The planner solves an amount against pool state, so an unstable fork point
        // does not just flake, it silently plans against the wrong state.
        forkBlock = vm.envOr("LIVE_FORK_BLOCK", uint256(0));
        require(forkBlock != 0, "LIVE_FORK_BLOCK required: the planner must fork at an explicit block, not the head");
        require(forkBlock >= MIN_FORK_BLOCK, "LIVE_FORK_BLOCK is before the demo pool was deployed");

        vm.createSelectFork(rpc, forkBlock);
        forked = true;
        poolId = LiveDemo.poolKey().toId();

        _preflight();
        _prepareWallet();
    }

    // ---------------------------------------------------------------------------------
    // Phase 1 — preflight
    // ---------------------------------------------------------------------------------

    function _preflight() internal view {
        assertEq(block.chainid, LiveDemo.CHAIN_ID, "wrong chain");

        // 1. The key in LiveDemo must hash to the pool that is actually live.
        assertEq(PoolId.unwrap(poolId), EXPECTED_POOL_ID, "computed pool id is not the live pool");

        // 2. Hook identity.
        assertGt(LiveDemo.HOOK.code.length, 0, "hook has no code");
        assertEq(uint160(LiveDemo.HOOK) & 0x3FFF, LiveDemo.REQUIRED_HOOK_MASK, "hook mask");
        assertEq(address(hook.poolManager()), LiveDemo.POOL_MANAGER, "hook poolManager");
        assertEq(hook.owner(), LiveDemo.DEPLOYER, "hook owner");
        assertEq(hook.OBSERVATION_BLOCKS(), 10, "observation horizon");

        // 3. Liquidity is present at THIS block.
        uint128 liquidity = poolManager.getLiquidity(poolId);
        assertGt(liquidity, 0, "pool has no liquidity at LIVE_FORK_BLOCK");

        // 5, 6. The pool is initialised and its tick is readable.
        (uint160 sqrtPriceX96, int24 startTick,,) = poolManager.getSlot0(poolId);
        assertTrue(sqrtPriceX96 != 0, "pool slot0 is uninitialised");

        // 7. Balances.
        assertGt(IERC20Minimal(LiveDemo.BUSDC).balanceOf(trader), LiveDemo.FORWARD_USDC, "bUSDC balance");
        assertGt(IERC20Minimal(LiveDemo.BWETH).balanceOf(trader), 10e18, "bWETH balance");

        console2.log("== fork preflight ==");
        console2.log("FORK BLOCK:");
        console2.log("  ", forkBlock);
        console2.log("COMPUTED POOL ID:");
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log("EXPECTED POOL ID:");
        console2.logBytes32(EXPECTED_POOL_ID);
        console2.log("LIQUIDITY:");
        console2.log("  ", uint256(liquidity));
        console2.log("START TICK:");
        console2.log("  ", int256(startTick));

        // 4. Deployment liquidity is the expectation, not a requirement: someone adding or
        // removing liquidity on a testnet pool is legitimate, and failing the run for it
        // would be wrong. It is reported so a changed pool is never mistaken for the old one.
        if (liquidity != EXPECTED_LIQUIDITY) {
            console2.log("  NOTE: liquidity differs from the deployment value", uint256(EXPECTED_LIQUIDITY));
        }
    }

    /// @dev Models the prepared wallet the live run requires. On the live chain these are
    /// separate transactions sent BEFORE the rehearsal begins.
    function _prepareWallet() internal {
        vm.startPrank(trader);
        for (uint256 i = 0; i < 2; i++) {
            address token = i == 0 ? LiveDemo.BWETH : LiveDemo.BUSDC;
            IERC20Minimal(token).approve(LiveDemo.PERMIT2, PREPARED_ALLOWANCE);
            IPermit2Minimal(LiveDemo.PERMIT2)
                .approve(token, LiveDemo.UNIVERSAL_ROUTER, uint160(PREPARED_ALLOWANCE), uint48(block.timestamp + 3600));
        }
        vm.stopPrank();
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    function _abs(int24 value) internal pure returns (int24) {
        return value < 0 ? -value : value;
    }

    // ---------------------------------------------------------------------------------
    // Phases 2-3 — plan the reverse amount against live state
    // ---------------------------------------------------------------------------------

    /// @dev Finds the bWETH exact-input amount that brings the tick back closest to T0.
    ///
    /// Selling back exactly what the forward produced always undershoots, because the fee
    /// is taken from the input on both legs. The true answer is a little above that, and
    /// binary search finds it without any hard-coded fudge factor.
    function _planReverseAmount(int24 t0) internal returns (uint128 best, int24 bestTick, int24 forwardTick) {
        uint256 beforeForward = vm.snapshotState();

        vm.prank(trader);
        LiveDemo.swapExactInput(false, LiveDemo.FORWARD_USDC, 0, trader);
        forwardTick = _tick();

        uint256 afterForward = vm.snapshotState();

        // The forward moved the tick up; the reverse must bring it back down. Bracket the
        // search generously and let the search narrow it.
        uint128 lo = 1e18;
        uint128 hi = 20e18;
        int24 bestDistance = type(int24).max;

        for (uint256 i = 0; i < 24; i++) {
            uint128 mid = uint128((uint256(lo) + uint256(hi)) / 2);

            vm.prank(trader);
            LiveDemo.swapExactInput(true, mid, 0, trader);
            int24 resultTick = _tick();
            vm.revertToState(afterForward);

            int24 distance = _abs(resultTick - t0);
            if (distance < bestDistance) {
                bestDistance = distance;
                best = mid;
                bestTick = resultTick;
            }

            // Selling more bWETH pushes the tick further down.
            if (resultTick > t0) lo = mid;
            else hi = mid;

            if (hi - lo <= 1) break;
        }

        vm.revertToState(beforeForward);
    }

    // ---------------------------------------------------------------------------------
    // The rehearsal
    // ---------------------------------------------------------------------------------

    /// @dev Everything the phases hand to one another, kept off the stack.
    struct Run {
        int24 t0;
        int24 forwardTick;
        int24 plannedTick;
        uint128 reverseAmount;
        bytes32 bondA;
        uint256 openBlockA;
        uint256 maturityA;
        uint128 collateralA;
        uint16 collateralBpsA;
        address recipientA;
        uint256 reverseBlock;
        int24 postReverseTick;
    }

    function test_liveRefundScenario() public {
        Run memory run;
        run.t0 = _tick();

        _plan(run);
        _forward(run);
        _reverse(run);
        _settleAndVerify(run);
    }

    /// @dev Phases 2-4: read the starting state, solve for the reverse amount, guard staleness.
    function _plan(Run memory run) internal {
        console2.log("== plan ==");
        console2.log("  start block            ", block.number);
        console2.log("  T0 (start tick)        ", int256(run.t0));

        (run.reverseAmount, run.plannedTick, run.forwardTick) = _planReverseAmount(run.t0);
        int24 plannedResidual = _abs(run.plannedTick - run.t0);

        console2.log("  forward post tick      ", int256(run.forwardTick));
        console2.log("  forward impact ticks   ", int256(_abs(run.forwardTick - run.t0)));
        console2.log("  planned reverse (raw)  ", uint256(run.reverseAmount));
        console2.log("  simulated recovered    ", int256(run.plannedTick));
        console2.log("  residual ticks         ", int256(plannedResidual));

        require(plannedResidual <= MAX_RESIDUAL, "rehearsal: cannot recover within 5 ticks");
        if (plannedResidual > TARGET_RESIDUAL) {
            console2.log("  NOTE: residual above the preferred 2 ticks, within the accepted 5.");
        }

        // Phase 4 staleness guard: the plan is only valid for the state it was made against.
        assertEq(_tick(), run.t0, "pool moved between planning and execution");
    }

    /// @dev Phase 5: the forward trade, with bond A taken straight from the receipt logs.
    function _forward(Run memory run) internal {
        vm.recordLogs();
        vm.prank(trader);
        LiveDemo.swapExactInput(false, LiveDemo.FORWARD_USDC, 0, trader);

        (bytes32 bondId,,) = _findBondOpened(vm.getRecordedLogs());
        require(bondId != bytes32(0), "rehearsal: forward produced no BondOpened");

        BondMeBro.Bond memory a = hook.getBond(bondId);
        run.bondA = bondId;
        run.openBlockA = a.openBlock;
        run.maturityA = a.maturityBlock;
        run.collateralA = hook.collateralAmountOf(bondId);
        run.collateralBpsA = a.collateralBps;
        run.recipientA = a.refundRecipient;

        assertEq(run.openBlockA, block.number, "openBlock");
        assertEq(run.maturityA, run.openBlockA + 10, "maturity must be open + 10");
        assertGt(a.collateralBps, 0, "bond A took no collateral");
        // Exact input spends currency1 here, so the collateral is currency0: bWETH.
        assertTrue(a.collateralIsCurrency0, "bond A collateral should be bWETH");
        assertEq(a.refundRecipient, trader, "refund recipient must be the deployer");

        console2.log("== bond A ==");
        console2.log("  open block             ", run.openBlockA);
        console2.log("  maturity block         ", run.maturityA);
        console2.log("  collateral (raw bWETH) ", uint256(run.collateralA));
        console2.log("  collateral bps         ", uint256(run.collateralBpsA));
        console2.log("  tickBefore             ", int256(a.tickBefore));
        console2.log("  tickAfter              ", int256(a.tickAfter));
    }

    /// @dev Phase 6: the precomputed reverse trade, and the timing requirement.
    function _reverse(Run memory run) internal {
        // Two consecutive live transactions land a block or two apart on a one-second chain.
        vm.roll(block.number + REVERSE_DELAY_BLOCKS);

        vm.prank(trader);
        LiveDemo.swapExactInput(true, run.reverseAmount, 0, trader);

        run.reverseBlock = block.number;
        run.postReverseTick = _tick();

        uint256 reverseDelay = run.reverseBlock - run.openBlockA;
        int24 residual = _abs(run.postReverseTick - run.t0);

        console2.log("== reverse ==");
        console2.log("  reverse block          ", run.reverseBlock);
        console2.log("  blocks after open      ", reverseDelay);
        console2.log("  post-reverse tick      ", int256(run.postReverseTick));
        console2.log("  residual from T0       ", int256(residual));

        // THE TIMING REQUIREMENT. C6 is the first observation, at open + 6.
        assertLt(reverseDelay, 6, "reverse must land before C6");
        assertLe(uint256(uint24(residual)), uint256(uint24(MAX_RESIDUAL)), "residual above 5 ticks");
    }

    /// @dev Phases 7-9: wait for maturity, settle permissionlessly, verify the economics.
    function _settleAndVerify(Run memory run) internal {
        vm.roll(run.maturityA);
        assertGe(block.number, run.maturityA, "not matured");

        assertEq(uint8(hook.getBond(run.bondA).state), 2, "bond A must be FINALIZED before settling");

        uint256 recipientBefore = IERC20Minimal(LiveDemo.BWETH).balanceOf(run.recipientA);
        uint256 potBefore = hook.insurancePot(poolId, Currency.wrap(LiveDemo.BWETH));

        vm.recordLogs();
        vm.prank(settler); // permissionless: not the recipient, not the owner
        hook.settleBond(run.bondA);

        (uint128 collateral, uint128 refund, uint128 slash, uint16 slashBps) =
            _findBondSettled(vm.getRecordedLogs(), run.bondA);

        console2.log("== settlement ==");
        console2.log("  original collateral    ", uint256(collateral));
        console2.log("  refund                 ", uint256(refund));
        console2.log("  slash                  ", uint256(slash));
        console2.log("  slash bps              ", uint256(slashBps));

        assertEq(collateral, run.collateralA, "settled collateral differs from taken amount");
        assertEq(uint256(refund) + uint256(slash), uint256(collateral), "refund + slash != collateral");
        assertEq(
            IERC20Minimal(LiveDemo.BWETH).balanceOf(run.recipientA) - recipientBefore,
            refund,
            "refund did not reach the stored recipient"
        );
        assertEq(
            hook.insurancePot(poolId, Currency.wrap(LiveDemo.BWETH)) - potBefore,
            slash,
            "reserve did not receive the slash"
        );
        assertEq(uint8(hook.getBond(run.bondA).state), 3, "bond A should be SETTLED");

        // THE POINT OF THE WHOLE EXERCISE.
        assertGt(refund, 0, "a reverted price move must refund something");
        assertEq(slashBps, 0, "full reversion should leave no slash");
        assertEq(refund, collateral, "expected a FULL refund");

        console2.log("== result ==");
        console2.log(
            "  FULL REFUND on bond A. Reverse landed this many blocks after open:", run.reverseBlock - run.openBlockA
        );
    }

    // ---------------------------------------------------------------------------------
    // Log helpers. Topic hashes come from the contract's own events, never a string.
    // ---------------------------------------------------------------------------------

    function _findBondOpened(Vm.Log[] memory logs)
        internal
        view
        returns (bytes32 bondId, uint128 variableLegAmount, uint32 maturityBlock)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != LiveDemo.HOOK) continue;
            if (logs[i].topics.length != 4) continue;
            if (logs[i].topics[0] != BondMeBro.BondOpened.selector) continue;
            if (logs[i].topics[2] != PoolId.unwrap(poolId)) continue;
            bondId = logs[i].topics[1];
            (variableLegAmount, maturityBlock) = abi.decode(logs[i].data, (uint128, uint32));
            return (bondId, variableLegAmount, maturityBlock);
        }
    }

    function _findBondSettled(Vm.Log[] memory logs, bytes32 wanted)
        internal
        pure
        returns (uint128 collateral, uint128 refund, uint128 slash, uint16 slashBps)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != LiveDemo.HOOK) continue;
            if (logs[i].topics.length != 4) continue;
            if (logs[i].topics[0] != BondMeBro.BondSettled.selector) continue;
            if (logs[i].topics[1] != wanted) continue;
            (, collateral, refund, slash, slashBps) =
                abi.decode(logs[i].data, (address, uint128, uint128, uint128, uint16));
            return (collateral, refund, slash, slashBps);
        }
        revert("rehearsal: BondSettled not emitted");
    }
}
