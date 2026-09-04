// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20Minimal, IPermit2Minimal, LiveDemo} from "./LiveDemo.sol";

/// @title PrepareWallet
/// @notice Grants the allowances the refund rehearsal needs, BEFORE the timed sequence.
///
/// @dev Approvals must never sit between the forward and reverse trades. The reverse has to
/// land inside six blocks, and a wallet prompt in the middle is exactly what would push it
/// past the first observation checkpoint.
///
/// Both grants are bounded and expire within the hour; nothing here is unlimited.
///
///   forge script script/live-refund-demo/PrepareWallet.s.sol:PrepareWallet \
///     --rpc-url https://sepolia.unichain.org \
///     --account bondmebro-deployer --sender 0xA5B709025224bA08B8eFfF1b0D1d28E970A34Cf3 \
///     --broadcast
contract PrepareWallet is Script {
    /// @notice bWETH headroom: several reverse legs of roughly 3.6 bWETH each.
    uint256 internal constant BWETH_SESSION = 40e18;

    /// @notice bUSDC headroom: several forward legs of 10,000 bUSDC each.
    uint256 internal constant BUSDC_SESSION = 100_000e6;

    /// @notice Permit2 grants expire in one hour, as everywhere else in this project.
    uint48 internal constant SESSION_SECONDS = 3600;

    function run() external {
        address deployer = msg.sender;
        require(block.chainid == LiveDemo.CHAIN_ID, "PrepareWallet: wrong chain");
        require(deployer == LiveDemo.DEPLOYER, "PrepareWallet: unexpected sender");

        vm.startBroadcast();
        _grant(LiveDemo.BWETH, BWETH_SESSION);
        _grant(LiveDemo.BUSDC, BUSDC_SESSION);
        vm.stopBroadcast();

        _report(deployer);
    }

    function _grant(address token, uint256 amount) internal {
        IERC20Minimal(token).approve(LiveDemo.PERMIT2, amount);
        IPermit2Minimal(LiveDemo.PERMIT2)
            .approve(token, LiveDemo.UNIVERSAL_ROUTER, uint160(amount), uint48(block.timestamp) + SESSION_SECONDS);
    }

    function _report(address deployer) internal view {
        console2.log("== allowances after preparation ==");
        _line("bWETH", LiveDemo.BWETH, deployer);
        _line("bUSDC", LiveDemo.BUSDC, deployer);
    }

    function _line(string memory label, address token, address deployer) internal view {
        uint256 toPermit2 = IERC20Minimal(token).allowance(deployer, LiveDemo.PERMIT2);
        (uint160 toRouter, uint48 expiration,) =
            IPermit2Minimal(LiveDemo.PERMIT2).allowance(deployer, token, LiveDemo.UNIVERSAL_ROUTER);
        console2.log(label);
        console2.log("  erc20 -> permit2 ", toPermit2);
        console2.log("  permit2 -> router", uint256(toRouter));
        console2.log("  expires at       ", uint256(expiration));
    }
}
