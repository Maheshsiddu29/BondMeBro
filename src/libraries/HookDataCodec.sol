// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

/// @title HookDataCodec

/// @notice Encodes and decodes the `hookData` attached to BondMeBro swaps. The payload tells the hook who should receive a future refund and the maximum bond amount the trader is willing to accept.

/// @dev BondMeBro must not use the swap callback `sender` as the refund recipient because, on supported routed swaps, that address is typically the router rather than the trader. `tx.origin` is also intentionally not used. The refund recipient is therefore provided explicitly through `hookData` by the caller building the swap.

/// The payload is versioned so its format can change later without silently misreading old or new calldata. Version 2 uses a packed 37-byte format:
///
/// offset | size | field           | type    | units
/// -------|------|-----------------|---------|-------------------------------------
/// 0      | 1    | version         | uint8   | schema version
/// 1      | 20   | refundRecipient | address | address
/// 21     | 16   | maxBondAmount   | uint128 | raw units of the COLLATERAL currency
///
/// Total: 37 bytes.

/// VERSION 2 — WHAT CHANGED, AND WHY IT IS A NEW VERSION RATHER THAN A REWORDING.
///
/// The byte layout is byte-for-byte identical to version 1. Only the *unit* of `maxBondAmount`
/// changed, and that is precisely why the version had to move: a stale version 1 payload is
/// indistinguishable from a version 2 payload by length or shape, so length validation alone
/// could never separate them.
///
/// Version 1 documented `maxBondAmount` in raw units of the swap's INPUT currency, because
/// collateral was always taken from the input. Under the variable-leg architecture
/// (ADR-0006) collateral is taken from the VARIABLE leg of the swap:
///
///   exact-input  — the input is fixed, so the collateral currency is the OUTPUT currency
///   exact-output — the output is fixed, so the collateral currency is the INPUT currency
///
/// So for an exact-input swap the ceiling is now denominated in the token the trader is BUYING.
/// A version 1 payload reused unchanged would express the ceiling in the wrong token, possibly
/// with a different decimal scale — a ceiling that is silently thousands of times too large or
/// too small. Version 1 is therefore REJECTED outright rather than reinterpreted, upgraded, or
/// accepted alongside version 2. It fails loudly at `decode`.
///
/// STAGING NOTE. This library defines the version 2 MEANING. The custody change that makes the
/// collateral currency actually vary by swap kind lands separately (migration stage P-L2-4);
/// until then the hook still physically takes collateral from the input currency. The two are
/// staged apart deliberately and nothing is deployed between stages, so no integration ever
/// observes the intermediate combination. Do not add transitional dual semantics here to close
/// that window — a codec that means two things at once is the defect this version bump exists
/// to prevent.

/// The payload uses `abi.encodePacked` instead of normal `abi.encode`. This keeps the calldata small and places the version at byte 0, allowing `decode` to inspect the schema version before interpreting the rest of the payload.

/// Validation order is intentional:
/// 1. reject empty data
/// 2. read and validate the version
/// 3. validate the exact payload length
/// 4. decode and validate the fields

/// This library is pure and stores no state. `encode` and `decode` enforce the same field-level validity rules so a payload produced by `encode` can also be read by `decode`.

library HookDataCodec {
    /// @notice HookData schema version supported by this build.
    /// @dev EXACTLY ONE version is supported at a time. There is no accepted-versions set, no
    ///      minimum version, and no fallback: `decode` compares against this constant and reverts
    ///      on anything else. Raising it retires the previous schema in the same edit.
    uint8 internal constant VERSION = 2;

    /// @notice Exact size of a version 2 payload: 1 + 20 + 16 = 37 bytes.
    /// @dev Unchanged from version 1. The length is deliberately NOT a version discriminator —
    ///      see the version-2 note in the library header for why only the version byte can
    ///      separate the two schemas.
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

    /// @notice Builds a valid version 2 hookData payload.

    /// @dev The recipient and maximum bond amount are validated before encoding. Invalid payloads used in negative tests must therefore be constructed manually rather than through this helper.

    /// @param refundRecipient Address intended to receive the bond refund at settlement.
    /// @param maxBondAmount Maximum refundable collateral the trader permits, in raw units of the COLLATERAL currency — the output currency for an exact-input swap, the input currency for an exact-output swap. Never in units of a currency the swap does not touch.
    /// @return data Packed 37-byte version 2 payload.
    function encode(address refundRecipient, uint128 maxBondAmount) internal pure returns (bytes memory data) {
        if (refundRecipient == address(0)) {
            revert ZeroRefundRecipient();
        }

        if (maxBondAmount == 0) {
            revert ZeroMaxBondAmount();
        }

        data = abi.encodePacked(VERSION, refundRecipient, maxBondAmount);
    }

    /// @notice Decodes and validates a version 2 hookData payload.

    /// @dev This function either returns a valid non-zero refund recipient and bond ceiling or reverts. There is no fallback or lenient decoding path.

    /// `maxBondAmount` is bond-specific execution protection. Pool thresholds and `bondBps` are owner-configurable, so the bond required when a transaction executes may differ from the value shown when the transaction was prepared. The trader-provided ceiling prevents BondMeBro from silently taking more collateral than the trader allowed.

    /// This function only reads and validates `maxBondAmount`. The actual ceiling check happens later when the hook has calculated the bond:
    ///
    /// `bond <= maxBondAmount`

    /// @param data Raw hookData supplied with the swap.
    /// @return refundRecipient Validated non-zero intended refund recipient. Taken ONLY from this payload — never from `sender`, the router, or `tx.origin`.
    /// @return maxBondAmount Validated non-zero collateral ceiling, in raw units of the COLLATERAL currency (exact-input: the output currency; exact-output: the input currency).
    function decode(bytes calldata data) internal pure returns (address refundRecipient, uint128 maxBondAmount) {
        if (data.length == 0) {
            revert MissingHookData();
        }

        // Read the version FIRST, before the length check, and this ordering is load-bearing
        // rather than stylistic. A version 1 payload has the same 37-byte shape as a version 2
        // one, so a length check could never reject it; only the version byte can. Checking
        // version first also means a future schema of a different size is reported as an
        // unsupported version rather than mislabelled as malformed version 2 data.
        uint8 version = uint8(data[0]);

        if (version != VERSION) {
            revert UnsupportedHookDataVersion(version);
        }

        // Version 2 must be exactly 37 bytes.
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
