// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {BondMeBro} from "../../src/BondMeBro.sol";
import {IERC20Minimal, IPermit2Minimal, LiveDemo} from "./LiveDemo.sol";

/// @title ExecuteRefundDemo
/// @notice Broadcasts the timed pair: forward 10,000 bUSDC, then the precomputed reverse.
///
/// @dev Both transactions go out from ONE invocation so nothing human sits between them.
/// The reverse must land before the first observation checkpoint at opening block + 6; on a
/// one-second chain two consecutive transactions land a block or two apart, which
/// `test/fork/LiveRefundRehearsal.t.sol` rehearses explicitly.
///
/// REVERSE_AMOUNT comes from that rehearsal. It is not guessed here, and it is not
/// recomputed here either: a binary search inside a broadcasting script would mean the
/// recorded transactions no longer match the state they were planned against.
///
///   REVERSE_AMOUNT=<raw bWETH> \
///   forge script script/live-refund-demo/ExecuteRefundDemo.s.sol:ExecuteRefundDemo \
///     --rpc-url https://sepolia.unichain.org \
///     --account bondmebro-deployer --sender 0xA5B709025224bA08B8eFfF1b0D1d28E970A34Cf3 \
///     --broadcast --slow
contract ExecuteRefundDemo is Script {
    using StateLibrary for IPoolManager;

    /// @dev The plan is only valid for the tick it was made against.
    int24 internal constant MAX_STALENESS_TICKS = 1;

    /// @dev Refuse a Permit2 grant that would lapse mid-sequence.
    uint48 internal constant MIN_REMAINING_SECONDS = 300;

    IPoolManager internal poolManager = IPoolManager(LiveDemo.POOL_MANAGER);
    BondMeBro internal hook = BondMeBro(LiveDemo.HOOK);

    function run() external {
        address deployer = msg.sender;
        uint128 reverseAmount = uint128(vm.envUint("REVERSE_AMOUNT"));
        int24 plannedT0 = int24(vm.envInt("PLANNED_T0"));

        PoolId poolId = LiveDemo.poolKey().toId();

        _preflight(deployer, reverseAmount, poolId);
        _stalenessGuard(poolId, plannedT0);

        console2.log("== executing ==");
        console2.log("  forward  (raw bUSDC)   ", uint256(LiveDemo.FORWARD_USDC));
        console2.log("  reverse  (raw bWETH)   ", uint256(reverseAmount));

        vm.startBroadcast();
        // Forward: spend currency1 (bUSDC) for currency0 (bWETH). Collateral is bWETH.
        LiveDemo.swapExactInput(false, LiveDemo.FORWARD_USDC, 0, deployer);
        // Reverse: spend currency0 (bWETH) to push the tick back to T0.
        LiveDemo.swapExactInput(true, reverseAmount, 0, deployer);
        vm.stopBroadcast();

        console2.log("  both transactions submitted. Read bond A from the FORWARD receipt.");
    }

    /// @dev Phase 1. Fails closed on anything that could interrupt the timed pair.
    function _preflight(address deployer, uint128 reverseAmount, PoolId poolId) internal view {
        require(block.chainid == LiveDemo.CHAIN_ID, "preflight: wrong chain");
        require(deployer == LiveDemo.DEPLOYER, "preflight: unexpected sender");
        require(LiveDemo.HOOK.code.length > 0, "preflight: hook has no code");
        require(uint160(LiveDemo.HOOK) & 0x3FFF == LiveDemo.REQUIRED_HOOK_MASK, "preflight: hook mask");
        require(address(hook.poolManager()) == LiveDemo.POOL_MANAGER, "preflight: hook poolManager");
        require(hook.owner() == LiveDemo.DEPLOYER, "preflight: hook owner");
        require(hook.OBSERVATION_BLOCKS() == 10, "preflight: observation horizon");
        require(poolManager.getLiquidity(poolId) > 0, "preflight: pool has no liquidity");
        require(reverseAmount > 0, "preflight: REVERSE_AMOUNT not set");

        require(
            IERC20Minimal(LiveDemo.BUSDC).balanceOf(deployer) >= LiveDemo.FORWARD_USDC,
            "preflight: bUSDC balance too low"
        );
        require(IERC20Minimal(LiveDemo.BWETH).balanceOf(deployer) >= reverseAmount, "preflight: bWETH balance too low");
        require(deployer.balance > 0.005 ether, "preflight: ETH gas balance too low");

        // BOTH directions must already be approved. An approval inside the timed sequence
        // is precisely what would push the reverse past C6.
        _requireAllowance(deployer, LiveDemo.BUSDC, LiveDemo.FORWARD_USDC, "bUSDC");
        _requireAllowance(deployer, LiveDemo.BWETH, reverseAmount, "bWETH");
    }

    function _requireAllowance(address deployer, address token, uint256 needed, string memory label) internal view {
        uint256 toPermit2 = IERC20Minimal(token).allowance(deployer, LiveDemo.PERMIT2);
        if (toPermit2 < needed) {
            console2.log("WALLET PREPARATION REQUIRED:", label, "erc20 -> permit2 allowance is", toPermit2);
            console2.log("  needed:", needed);
            revert("preflight: WALLET PREPARATION REQUIRED (erc20 -> permit2)");
        }

        (uint160 toRouter, uint48 expiration,) =
            IPermit2Minimal(LiveDemo.PERMIT2).allowance(deployer, token, LiveDemo.UNIVERSAL_ROUTER);
        if (uint256(toRouter) < needed) {
            console2.log("WALLET PREPARATION REQUIRED:", label, "permit2 -> router allowance is", uint256(toRouter));
            console2.log("  needed:", needed);
            revert("preflight: WALLET PREPARATION REQUIRED (permit2 -> router)");
        }
        if (uint256(expiration) < block.timestamp + MIN_REMAINING_SECONDS) {
            console2.log("WALLET PREPARATION REQUIRED:", label, "permit2 grant expires at", uint256(expiration));
            console2.log("  now:", block.timestamp);
            revert("preflight: WALLET PREPARATION REQUIRED (permit2 grant expiring)");
        }
    }

    /// @dev Phase 4. A reverse amount solved against a different tick is the wrong amount.
    function _stalenessGuard(PoolId poolId, int24 plannedT0) internal view {
        (, int24 liveTick,,) = poolManager.getSlot0(poolId);
        int24 drift = liveTick - plannedT0;
        if (drift < 0) drift = -drift;

        console2.log("== staleness guard ==");
        console2.log("  planned T0             ", int256(plannedT0));
        console2.log("  live tick              ", int256(liveTick));
        console2.log("  drift ticks            ", int256(drift));

        require(drift <= MAX_STALENESS_TICKS, "staleness: pool moved since planning, re-plan before executing");
    }
}
