// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title HookDataCodec
/// @notice Encodes the user-controlled refund recipient and bond slippage limit passed to a
///         BondMeBro swap.
///
/// @dev The wire format is deliberately fixed-width and versioned:
///
///      byte 0       version (currently 1)
///      bytes 1..20  refund recipient
///      bytes 21..36 maximum bond amount, uint128 big-endian
///
///      `abi.decode` is intentionally not used here. It would accept multiple dynamic layouts
///      and would make it too easy for a router to accidentally pass an address-only payload
///      while silently omitting the trader's bond limit.
library HookDataCodec {
    uint8 internal constant VERSION = 1;
    uint256 internal constant LENGTH = 37;

    error InvalidHookDataLength();
    error InvalidHookDataVersion();
    error InvalidRefundRecipient();
    error InvalidMaxBondAmount();

    /// @notice Encodes a version-1 hook payload.
    /// @param refundRecipient Address that receives a refund and piggyback settlement reward.
    /// @param maxBondAmount Maximum bond accepted by the trader.
    function encode(address refundRecipient, uint128 maxBondAmount) internal pure returns (bytes memory) {
        if (refundRecipient == address(0)) revert InvalidRefundRecipient();
        if (maxBondAmount == 0) revert InvalidMaxBondAmount();
        return abi.encodePacked(bytes1(VERSION), refundRecipient, maxBondAmount);
    }

    /// @notice Decodes and validates a version-1 hook payload.
    function decode(bytes calldata data) internal pure returns (address refundRecipient, uint128 maxBondAmount) {
        if (data.length != LENGTH) revert InvalidHookDataLength();

        uint8 version;
        assembly ("memory-safe") {
            version := byte(0, calldataload(data.offset))
        }
        if (version != VERSION) revert InvalidHookDataVersion();

        assembly ("memory-safe") {
            refundRecipient := shr(96, calldataload(add(data.offset, 1)))
            maxBondAmount := shr(128, calldataload(add(data.offset, 21)))
        }

        if (refundRecipient == address(0)) revert InvalidRefundRecipient();
        if (maxBondAmount == 0) revert InvalidMaxBondAmount();
    }
}
