// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

/// @title HookDataCodec
/// @notice Builds and reads the recipient and collateral ceiling attached to a swap.
/// @dev hookData is a packed 37-byte message:
/// byte 0 is version 2; bytes 1-20 are the refund address; bytes 21-36 are
/// maxBondAmount, a uint128 measured in raw units of the collateral token.
/// That token is output for exact-input and input for exact-output.
///
/// The recipient is explicit because a swap callback's sender is usually a router,
/// not the person entitled to a refund. Neither sender nor tx.origin is used.
///
/// The version byte prevents an unsupported format or token-unit meaning from
/// being silently accepted. Only version 2 is accepted. Empty input, unknown
/// versions, incorrect lengths, zero recipients and zero ceilings all revert.
/// The library is pure: it reads bytes and stores nothing.
library HookDataCodec {
    /// @notice Only supported payload version. Other version bytes are rejected.
    uint8 internal constant VERSION = 2;

    /// @notice Exact payload length: 1 version byte + 20 address bytes + 16 amount bytes.
    uint256 internal constant ENCODED_LENGTH = 37;

    /// @dev Refund address begins immediately after the version byte.
    uint256 private constant OFFSET_RECIPIENT = 1;

    /// @dev The uint128 collateral ceiling starts after the version and address, at byte 21.
    uint256 private constant OFFSET_MAX_BOND = 21;

    /// @notice A path requiring a recipient and collateral ceiling received empty data.
    error MissingHookData();

    /// @notice The first byte names a payload version this library does not support.
    /// @param version Version supplied by the caller.
    error UnsupportedHookDataVersion(uint8 version);

    /// @notice A supported-version message has the wrong length.
    /// @dev Truncated messages and extra bytes both revert; no trailing fields are ignored.
    /// @param expected Required byte count.
    /// @param actual Supplied byte count.
    error InvalidHookDataLength(uint256 expected, uint256 actual);

    /// @notice The refund recipient must be a non-zero address.
    error ZeroRefundRecipient();

    /// @notice A zero ceiling cannot authorize positive collateral and is rejected.
    error ZeroMaxBondAmount();

    /// @notice Encodes a validated recipient and ceiling as a packed version 2 message.
    /// @dev Both fields must be non-zero. Packed encoding keeps the message at 37 bytes
    /// and puts the version first, instead of padding each field to 32 bytes.
    /// @param refundRecipient Address entitled to the future refund.
    /// @param maxBondAmount Maximum collateral in raw output-token units for exact-input,
    /// or raw input-token units for exact-output.
    /// @return data Packed message suitable for decode and the hook's swap callbacks.
    function encode(address refundRecipient, uint128 maxBondAmount) internal pure returns (bytes memory data) {
        if (refundRecipient == address(0)) {
            revert ZeroRefundRecipient();
        }

        if (maxBondAmount == 0) {
            revert ZeroMaxBondAmount();
        }

        data = abi.encodePacked(VERSION, refundRecipient, maxBondAmount);
    }

    /// @notice Decodes a version 2 message, or reverts if its format or fields are invalid.
    /// @dev We check empty input, version, exact length, then fields in that order.
    /// Checking the version before length reports an unsupported schema as such,
    /// rather than interpreting its bytes using this version's rules.
    ///
    /// maxBondAmount is slippage protection for collateral. The rate depends on
    /// execution and earlier swaps in the block, so a quote-derived token ceiling
    /// can become stale. This library validates the ceiling but does not calculate
    /// collateral; the hook later enforces bond <= maxBondAmount.
    ///
    /// For routed exact-input swaps, the integration policy uses type(uint128).max
    /// here and protects final net output with amountOutMinimum. For exact-output,
    /// the ceiling and total maximum input are derived from the fixed collateral cap.
    /// Ordinary price slippage is separate from that cap.
    /// @param data Raw hookData supplied with the swap.
    /// @return refundRecipient Non-zero refund destination supplied in this message.
    /// @return maxBondAmount Non-zero ceiling in raw units of the collateral token.
    function decode(bytes calldata data) internal pure returns (address refundRecipient, uint128 maxBondAmount) {
        if (data.length == 0) {
            revert MissingHookData();
        }

        uint8 version = uint8(data[0]);

        if (version != VERSION) {
            revert UnsupportedHookDataVersion(version);
        }

        if (data.length != ENCODED_LENGTH) {
            revert InvalidHookDataLength(ENCODED_LENGTH, data.length);
        }

        refundRecipient = address(bytes20(data[OFFSET_RECIPIENT:OFFSET_MAX_BOND]));

        maxBondAmount = uint128(bytes16(data[OFFSET_MAX_BOND:ENCODED_LENGTH]));

        if (refundRecipient == address(0)) {
            revert ZeroRefundRecipient();
        }

        if (maxBondAmount == 0) {
            revert ZeroMaxBondAmount();
        }
    }
}
