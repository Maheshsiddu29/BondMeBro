// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {BondMeBro} from "../../src/BondMeBro.sol";
import {IERC20Minimal, LiveDemo} from "./LiveDemo.sol";

/// @title SettleBondA
/// @notice Settles the rehearsal's bond A once it has matured, and reports the economics.
///
/// @dev Run this only after the chain has passed bond A's stored maturity block. The script
/// simulates `settleBond` during forge's dry run, so a revert surfaces with its decoded
/// custom error before anything is signed.
///
///   BOND_A=<bytes32> \
///   forge script script/live-refund-demo/SettleBondA.s.sol:SettleBondA \
///     --rpc-url https://sepolia.unichain.org \
///     --account bondmebro-deployer --sender 0xA5B709025224bA08B8eFfF1b0D1d28E970A34Cf3 \
///     --broadcast
contract SettleBondA is Script {
    BondMeBro internal hook = BondMeBro(LiveDemo.HOOK);

    function run() external {
        bytes32 bondA = vm.envBytes32("BOND_A");
        PoolId poolId = LiveDemo.poolKey().toId();

        require(block.chainid == LiveDemo.CHAIN_ID, "settle: wrong chain");

        BondMeBro.Bond memory bond = hook.getBond(bondA);
        uint128 collateral = hook.collateralAmountOf(bondA);

        console2.log("== bond A before settlement ==");
        console2.log("  state (2=FINALIZED)    ", uint256(bond.state));
        console2.log("  open block             ", uint256(bond.openBlock));
        console2.log("  maturity block         ", uint256(bond.maturityBlock));
        console2.log("  current block          ", block.number);
        console2.log("  collateral (raw)       ", uint256(collateral));
        console2.log("  collateral bps         ", uint256(bond.collateralBps));
        console2.log("  refund recipient       ", bond.refundRecipient);

        require(uint8(bond.state) == 2, "settle: bond A is not FINALIZED");
        require(block.number >= bond.maturityBlock, "settle: bond A has not matured");

        address collateralToken = bond.collateralIsCurrency0 ? LiveDemo.BWETH : LiveDemo.BUSDC;
        uint256 recipientBefore = IERC20Minimal(collateralToken).balanceOf(bond.refundRecipient);
        uint256 potBefore = hook.insurancePot(poolId, Currency.wrap(collateralToken));

        vm.startBroadcast();
        hook.settleBond(bondA);
        vm.stopBroadcast();

        // Read back through storage rather than trusting the simulation's own log decode.
        BondMeBro.Bond memory after_ = hook.getBond(bondA);
        uint256 recipientAfter = IERC20Minimal(collateralToken).balanceOf(bond.refundRecipient);
        uint256 potAfter = hook.insurancePot(poolId, Currency.wrap(collateralToken));

        uint256 refund = recipientAfter - recipientBefore;
        uint256 slash = potAfter - potBefore;

        console2.log("== settlement result (simulated values; confirm on chain) ==");
        console2.log("  state (3=SETTLED)      ", uint256(after_.state));
        console2.log("  original collateral    ", uint256(collateral));
        console2.log("  refund to recipient    ", refund);
        console2.log("  retained to reserve    ", slash);
        console2.log("  refund + slash         ", refund + slash);

        require(refund + slash == collateral, "settle: refund + slash != collateral");
    }
}
