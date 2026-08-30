// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

/// @title HookDataCodec

/// @notice Encodes and decodes the `hookData` attached to BondMeBro swaps. The payload tells the hook who should receive a future refund and the maximum bond amount the trader is willing to accept.

/// @dev BondMeBro must not use the swap callback `sender` as the refund recipient because, on supported routed swaps, that address is typically the router rather than the trader. `tx.origin` is also intentionally not used. The refund recipient is therefore provided explicitly through `hookData` by the caller building the swap.

/// The payload is versioned so its format can change later without silently misreading old or new calldata. Version 1 uses a packed 37-byte format:
///
/// offset | size | field           | type    | units
/// -------|------|-----------------|---------|--------------------------------
/// 0      | 1    | version         | uint8   | schema version
/// 1      | 20   | refundRecipient | address | address
/// 21     | 16   | maxBondAmount   | uint128 | raw units of the input currency
///
/// Total: 37 bytes.

/// The payload uses `abi.encodePacked` instead of normal `abi.encode`. This keeps the calldata small and places the version at byte 0, allowing `decode` to inspect the schema version before interpreting the rest of the payload.

/// Validation order is intentional:
/// 1. reject empty data
/// 2. read and validate the version
/// 3. validate the exact payload length
/// 4. decode and validate the fields

/// This library is pure and stores no state. `encode` and `decode` enforce the same field-level validity rules so a payload produced by `encode` can also be read by `decode`.

library HookDataCodec {
    /// @notice HookData schema version supported by this build.
    uint8 internal constant VERSION = 1;

    /// @notice Exact size of a version 1 payload: 1 + 20 + 16 = 37 bytes.
    uint256 internal constant ENCODED_LENGTH = 37;

    /// @dev Byte offset where `refundRecipient` starts.
    uint256 private constant OFFSET_RECIPIENT = 1;

    /// @dev Byte offset where `maxBondAmount` starts.
    uint256 private constant OFFSET_MAX_BOND = 21;

    /// @notice Thrown when a swap that requires valid hookData provides no data.
    /// @dev Empty data is reported separately from malformed data because it usually means the caller did not supply BondMeBro hookData at all.
    error MissingHookData();

    /// @notice Thrown when the payload uses a hookData version this build does not support.
    /// @param version Version found at byte 0.
    error UnsupportedHookDataVersion(uint8 version);

    /// @notice Thrown when the payload does not have the exact length required by the supported schema.
    /// @dev Both shorter and longer payloads are rejected. Extra bytes are not silently ignored because they may represent fields that this version of BondMeBro does not understand.
    /// @param expected Required payload length.
    /// @param actual Received payload length.
    error InvalidHookDataLength(uint256 expected, uint256 actual);

    /// @notice Thrown when `refundRecipient` is the zero address.
    /// @dev A bond must always have a valid intended refund recipient before custody is accepted.
    error ZeroRefundRecipient();

    /// @notice Thrown when the trader-provided bond ceiling is zero.
    /// @dev A positive bond can never satisfy a zero ceiling, so the payload is rejected immediately instead of waiting until bond calculation.
    error ZeroMaxBondAmount();

    /// @notice Builds a valid version 1 hookData payload.

    /// @dev The recipient and maximum bond amount are validated before encoding. Invalid payloads used in negative tests must therefore be constructed manually rather than through this helper.

    /// @param refundRecipient Address intended to receive the bond refund once settlement/refunds are implemented.
    /// @param maxBondAmount Maximum BondMeBro collateral the trader is willing to post, in raw units of the swap's input currency.
    /// @return data Packed 37-byte version 1 payload.
    function encode(address refundRecipient, uint128 maxBondAmount) internal pure returns (bytes memory data) {
        if (refundRecipient == address(0)) {
            revert ZeroRefundRecipient();
        }

        if (maxBondAmount == 0) {
            revert ZeroMaxBondAmount();
        }

        data = abi.encodePacked(VERSION, refundRecipient, maxBondAmount);
    }

    /// @notice Decodes and validates a version 1 hookData payload.

    /// @dev This function either returns a valid non-zero refund recipient and bond ceiling or reverts. There is no fallback or lenient decoding path.

    /// `maxBondAmount` is bond-specific execution protection. Pool thresholds and `bondBps` are owner-configurable, so the bond required when a transaction executes may differ from the value shown when the transaction was prepared. The trader-provided ceiling prevents BondMeBro from silently taking more collateral than the trader allowed.

    /// This function only reads and validates `maxBondAmount`. The actual ceiling check happens later when the hook has calculated the bond:
    ///
    /// `bond <= maxBondAmount`

    /// @param data Raw hookData supplied with the swap.
    /// @return refundRecipient Validated non-zero intended refund recipient.
    /// @return maxBondAmount Validated non-zero bond ceiling, in raw units of the swap's input currency.
    function decode(bytes calldata data) internal pure returns (address refundRecipient, uint128 maxBondAmount) {
        if (data.length == 0) {
            revert MissingHookData();
        }

        // Read the version first so an unsupported schema is reported clearly.
        uint8 version = uint8(data[0]);

        if (version != VERSION) {
            revert UnsupportedHookDataVersion(version);
        }

        // Version 1 must be exactly 37 bytes.
        if (data.length != ENCODED_LENGTH) {
            revert InvalidHookDataLength(ENCODED_LENGTH, data.length);
        }

        // Length is now known to be correct, so both slices are in bounds.
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
