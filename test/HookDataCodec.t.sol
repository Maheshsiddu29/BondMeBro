// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";

/// @title HookDataCodecHarness

/// @notice External test harness for calling `HookDataCodec.decode`, which accepts `bytes calldata`.

/// @dev `decodeGas` measures only the gas spent inside the codec call after the external function has already received its calldata. This better represents the cost BondMeBro pays when decoding hookData inside a swap callback.
contract HookDataCodecHarness {
    function decode(bytes calldata data) external pure returns (address refundRecipient, uint128 maxBondAmount) {
        return HookDataCodec.decode(data);
    }

    function decodeGas(bytes calldata data)
        external
        view
        returns (uint256 gasUsed, address refundRecipient, uint128 maxBondAmount)
    {
        uint256 beforeGas = gasleft();

        (refundRecipient, maxBondAmount) = HookDataCodec.decode(data);

        gasUsed = beforeGas - gasleft();
    }
}

/// @title HookDataCodecTest

/// @notice Tests the HookDataCodec wire format, validation rules, fuzz properties, and decode gas cost.

/// @dev The versioned 37-byte payload is part of BondMeBro's integration interface, so these tests verify both semantic roundtrips and the exact byte layout. Malformed payloads must fail closed rather than being partially decoded or silently ignored.

/// VERSION 2. Version 1 had the SAME 37-byte shape and differed only in the unit of
/// `maxBondAmount`, so no length or structural check can separate the two — only the version
/// byte can. `test_version1_rejected` is therefore the most security-relevant test in this file
/// and must never be relaxed into a generic "unsupported version" case.
contract HookDataCodecTest is Test {
    HookDataCodecHarness internal harness;

    address internal constant RECIPIENT = address(0xBEEF);

    uint128 internal constant MAX_BOND = 1_000e18;

    /// @dev Regression ceiling for the isolated decode operation. If decoding exceeds this value, the increase should be reviewed rather than silently raising the limit.
    uint256 internal constant DECODE_GAS_CEILING = 1_500;

    function setUp() public {
        harness = new HookDataCodecHarness();
    }

    /*//////////////////////////////////////////////////////////////
                              HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @notice A valid payload preserves both encoded fields through encode and decode.
    function test_roundtrip() public view {
        bytes memory data = HookDataCodec.encode(RECIPIENT, MAX_BOND);

        (address recipient, uint128 maxBond) = harness.decode(data);

        assertEq(recipient, RECIPIENT, "recipient did not survive the roundtrip");

        assertEq(maxBond, MAX_BOND, "maxBondAmount did not survive the roundtrip");
    }

    /// @notice Verifies that version 2 is exactly 37 bytes and places the version byte at offset 0.

    /// @dev A roundtrip alone is not enough to protect a wire format because `encode` and `decode` could change together and still pass. These assertions pin the external byte-level format.
    function test_wireFormat_versionByteIsFirst() public pure {
        bytes memory data = HookDataCodec.encode(RECIPIENT, MAX_BOND);

        assertEq(data.length, HookDataCodec.ENCODED_LENGTH, "payload is not 37 bytes");

        assertEq(uint8(data[0]), HookDataCodec.VERSION, "version byte is not at offset 0");

        assertEq(HookDataCodec.VERSION, 2, "VERSION must be 2 after the v2 migration");

        assertEq(HookDataCodec.ENCODED_LENGTH, 37, "ENCODED_LENGTH drifted from 1 + 20 + 16");
    }

    /// @notice Verifies the exact packed position of every version 2 field.
    function test_wireFormat_fieldOffsets() public view {
        address recipient = address(0x00112233445566778899AABbCCdDeeFf00112233);

        uint128 maxBond = 0x0123456789ABCDEF0123456789ABCDEF;

        bytes memory data = HookDataCodec.encode(recipient, maxBond);

        assertEq(data, abi.encodePacked(uint8(2), recipient, maxBond), "packed layout changed");

        (address decodedRecipient, uint128 decodedMaxBond) = harness.decode(data);

        assertEq(decodedRecipient, recipient);

        assertEq(decodedMaxBond, maxBond);
    }

    /// @notice Verifies the smallest and largest valid field values survive the packed format without corruption.
    function test_extremeValues() public view {
        address maxAddress = address(type(uint160).max);

        uint128 maxBond = type(uint128).max;

        (address recipient, uint128 decodedMaxBond) = harness.decode(HookDataCodec.encode(maxAddress, maxBond));

        assertEq(recipient, maxAddress, "all-ones address mangled");

        assertEq(decodedMaxBond, maxBond, "type(uint128).max mangled");

        // Check the smallest non-zero values as well so neighbouring packed fields
        // cannot accidentally bleed into each other.
        (recipient, decodedMaxBond) = harness.decode(HookDataCodec.encode(address(1), 1));

        assertEq(recipient, address(1), "address(1) mangled");

        assertEq(decodedMaxBond, 1, "maxBondAmount 1 mangled");
    }

    /// @notice Pins each field's byte range independently, by reading the payload directly.
    ///
    /// @dev `test_wireFormat_fieldOffsets` compares against `abi.encodePacked`, which would still
    ///      pass if BOTH the codec and the expectation moved together. This reads the bytes at
    ///      their documented offsets by hand, so the wire format is pinned against the
    ///      DOCUMENTATION rather than against another encoder.
    function test_wireFormat_offsetsReadByHand() public view {
        address recipient = address(0x00112233445566778899AABbCCdDeeFf00112233);
        uint128 maxBond = 0x0123456789ABCDEF0123456789ABCDEF;

        bytes memory data = HookDataCodec.encode(recipient, maxBond);

        // byte 0: version
        assertEq(uint8(data[0]), 2, "offset 0 must hold version 2");

        // bytes 1..20: recipient, big-endian
        uint160 readRecipient;
        for (uint256 i = 1; i <= 20; i++) {
            readRecipient = (readRecipient << 8) | uint160(uint8(data[i]));
        }
        assertEq(address(readRecipient), recipient, "recipient is not at bytes 1..20");

        // bytes 21..36: uint128 maxBondAmount, big-endian
        uint128 readMaxBond;
        for (uint256 i = 21; i <= 36; i++) {
            readMaxBond = (readMaxBond << 8) | uint128(uint8(data[i]));
        }
        assertEq(readMaxBond, maxBond, "maxBondAmount is not at bytes 21..36");

        assertEq(data.length, 37, "payload is not exactly 37 bytes");
    }

    /// @notice Neither packed field bleeds into its neighbour at the boundaries.
    /// @dev An all-ones recipient beside a 1-wei ceiling, and the reverse, are the arrangements
    ///      an off-by-one offset would corrupt.
    function test_wireFormat_adjacentFieldsDoNotBleed() public view {
        (address r1, uint128 m1) = harness.decode(HookDataCodec.encode(address(type(uint160).max), 1));
        assertEq(r1, address(type(uint160).max), "all-ones recipient bled into maxBondAmount");
        assertEq(m1, 1, "maxBondAmount corrupted by a full recipient");

        (address r2, uint128 m2) = harness.decode(HookDataCodec.encode(address(1), type(uint128).max));
        assertEq(r2, address(1), "recipient corrupted by a full maxBondAmount");
        assertEq(m2, type(uint128).max, "all-ones maxBondAmount bled into the recipient");
    }

    /// @notice The documented ceiling boundaries survive a roundtrip.
    /// @dev `maxBondAmount == 0` is deliberately absent here: the codec REJECTS it (see
    ///      `test_zeroMaxBondAmount_reverts`), and that pre-existing rule is preserved by this
    ///      migration rather than changed by it.
    function test_maxBondAmount_boundaries() public view {
        (, uint128 one) = harness.decode(HookDataCodec.encode(RECIPIENT, 1));
        assertEq(one, 1, "maxBondAmount of 1 mangled");

        (, uint128 max) = harness.decode(HookDataCodec.encode(RECIPIENT, type(uint128).max));
        assertEq(max, type(uint128).max, "maxBondAmount of type(uint128).max mangled");

        (, uint128 mid) = harness.decode(HookDataCodec.encode(RECIPIENT, type(uint128).max / 2));
        assertEq(mid, type(uint128).max / 2, "mid-range maxBondAmount mangled");
    }

    /*//////////////////////////////////////////////////////////////
                         MALFORMED — DECODE
    //////////////////////////////////////////////////////////////*/

    /// @notice Empty hookData is rejected with `MissingHookData`.
    function test_empty_reverts() public {
        vm.expectRevert(HookDataCodec.MissingHookData.selector);

        harness.decode("");
    }

    /// @notice Every truncated version 2 payload is rejected.
    function test_truncated_reverts() public {
        bytes memory valid = HookDataCodec.encode(RECIPIENT, MAX_BOND);

        // Test every size from a version-only payload through one byte short.
        for (uint256 len = 1; len < HookDataCodec.ENCODED_LENGTH; len++) {
            bytes memory truncated = new bytes(len);

            for (uint256 i = 0; i < len; i++) {
                truncated[i] = valid[i];
            }

            vm.expectRevert(
                abi.encodeWithSelector(HookDataCodec.InvalidHookDataLength.selector, HookDataCodec.ENCODED_LENGTH, len)
            );

            harness.decode(truncated);
        }
    }

    /// @notice Payloads longer than the exact version 2 length are rejected rather than having trailing bytes ignored.
    function test_overLong_reverts() public {
        bytes memory valid = HookDataCodec.encode(RECIPIENT, MAX_BOND);

        bytes memory overLong = abi.encodePacked(valid, bytes1(0x00));

        vm.expectRevert(
            abi.encodeWithSelector(
                HookDataCodec.InvalidHookDataLength.selector, HookDataCodec.ENCODED_LENGTH, uint256(38)
            )
        );

        harness.decode(overLong);
    }

    /// @notice A payload created with normal `abi.encode` instead of the packed codec is rejected as an unsupported version.

    /// @dev `abi.encode(uint8, address, uint128)` produces three 32-byte words. The `uint8` is right-aligned inside the first word, so byte 0 is zero rather than the version. Because the codec reads the version before checking length, the error clearly identifies the schema mismatch.
    function test_abiEncodedPayload_revertsAsWrongVersion() public {
        bytes memory abiEncoded = abi.encode(HookDataCodec.VERSION, RECIPIENT, MAX_BOND);

        assertEq(abiEncoded.length, 96, "sanity: abi.encode of these three fields is 96 bytes");

        assertEq(uint8(abiEncoded[0]), 0, "sanity: abi.encode leaves byte 0 as padding");

        vm.expectRevert(abi.encodeWithSelector(HookDataCodec.UnsupportedHookDataVersion.selector, uint8(0)));

        harness.decode(abiEncoded);
    }

    /// @notice An unsupported FUTURE schema version is rejected.
    /// @dev This probe used version 2 before the migration. Version 2 is now the supported
    ///      schema, so the probe moved to 3 — had it been left alone it would have silently
    ///      become a "valid payload is accepted" test wearing this name.
    function test_futureVersion_reverts() public {
        bytes memory data = abi.encodePacked(uint8(3), RECIPIENT, MAX_BOND);

        vm.expectRevert(abi.encodeWithSelector(HookDataCodec.UnsupportedHookDataVersion.selector, uint8(3)));

        harness.decode(data);
    }

    /// @notice The maximum representable version byte is rejected.
    function test_version255_reverts() public {
        bytes memory data = abi.encodePacked(uint8(255), RECIPIENT, MAX_BOND);

        vm.expectRevert(abi.encodeWithSelector(HookDataCodec.UnsupportedHookDataVersion.selector, uint8(255)));

        harness.decode(data);
    }

    /*//////////////////////////////////////////////////////////////
                    VERSION 1 REJECTION — THE SECURITY CASE
    //////////////////////////////////////////////////////////////*/

    /// @notice A well-formed, previously-valid VERSION 1 payload is rejected.
    ///
    /// @dev THE REASON THIS FILE EXISTS IN ITS CURRENT FORM. Version 1 and version 2 have
    ///      byte-identical shape — same 37 bytes, same field offsets, same types — and differ
    ///      only in what `maxBondAmount` MEANS. Version 1 denominated it in the swap's INPUT
    ///      currency; version 2 denominates it in the COLLATERAL currency, which for an
    ///      exact-input swap is the OUTPUT.
    ///
    ///      So a stale version 1 payload replayed unchanged would express the trader's ceiling
    ///      in the wrong token — potentially with different decimals, making the ceiling orders
    ///      of magnitude too large or too small. **No length, shape or structural check can
    ///      detect that.** Only the version byte can, which is why `decode` reads it first and
    ///      why version 1 must fail loudly rather than be reinterpreted or upgraded.
    function test_version1_rejected() public {
        // Byte-for-byte what `encode` produced before the migration.
        bytes memory v1 = abi.encodePacked(uint8(1), RECIPIENT, MAX_BOND);

        assertEq(v1.length, HookDataCodec.ENCODED_LENGTH, "v1 shares v2 length, so length cannot separate them");

        vm.expectRevert(abi.encodeWithSelector(HookDataCodec.UnsupportedHookDataVersion.selector, uint8(1)));

        harness.decode(v1);
    }

    /// @notice Version 1 is rejected on the VERSION byte, not by accident of some other check.
    /// @dev Pins that the rejection survives even when every other field is perfectly valid —
    ///      a non-zero recipient, a non-zero ceiling and the exact expected length.
    function test_version1_rejectedEvenWhenOtherwisePerfect() public {
        bytes memory v1 = abi.encodePacked(uint8(1), address(0x1234), uint128(1));

        assertEq(v1.length, 37);

        vm.expectRevert(abi.encodeWithSelector(HookDataCodec.UnsupportedHookDataVersion.selector, uint8(1)));

        harness.decode(v1);
    }

    /// @notice Version zero is not treated as a valid version 1 payload.
    function test_versionZero_reverts() public {
        bytes memory data = abi.encodePacked(uint8(0), RECIPIENT, MAX_BOND);

        vm.expectRevert(abi.encodeWithSelector(HookDataCodec.UnsupportedHookDataVersion.selector, uint8(0)));

        harness.decode(data);
    }

    /// @notice Version validation happens before version 2 length validation.

    /// @dev A future payload with a different version and different size should be reported as unsupported rather than incorrectly reported as malformed version 2 data.
    function test_wrongVersion_isCheckedBeforeLength() public {
        bytes memory shortV3 = abi.encodePacked(uint8(3), bytes4(0xDEADBEEF));

        vm.expectRevert(abi.encodeWithSelector(HookDataCodec.UnsupportedHookDataVersion.selector, uint8(3)));

        harness.decode(shortV3);
    }

    /// @notice A SHORT version 1 payload is reported as an unsupported version, not a bad length.
    /// @dev Confirms there is no path on which a version 1 payload reaches the field decoders.
    function test_version1_shortPayload_reportsVersionNotLength() public {
        bytes memory shortV1 = abi.encodePacked(uint8(1), bytes4(0xDEADBEEF));

        vm.expectRevert(abi.encodeWithSelector(HookDataCodec.UnsupportedHookDataVersion.selector, uint8(1)));

        harness.decode(shortV1);
    }

    /// @notice A zero refund recipient is rejected.
    function test_zeroRecipient_reverts() public {
        bytes memory data = abi.encodePacked(HookDataCodec.VERSION, address(0), MAX_BOND);

        vm.expectRevert(HookDataCodec.ZeroRefundRecipient.selector);

        harness.decode(data);
    }

    /// @notice A zero trader bond ceiling is rejected.
    function test_zeroMaxBondAmount_reverts() public {
        bytes memory data = abi.encodePacked(HookDataCodec.VERSION, RECIPIENT, uint128(0));

        vm.expectRevert(HookDataCodec.ZeroMaxBondAmount.selector);

        harness.decode(data);
    }

    /*//////////////////////////////////////////////////////////////
                         MALFORMED — ENCODE
    //////////////////////////////////////////////////////////////*/

    /// @notice `encode` rejects a zero refund recipient just as `decode` does.
    function test_encode_rejectsZeroRecipient() public {
        vm.expectRevert(HookDataCodec.ZeroRefundRecipient.selector);

        this.callEncode(address(0), MAX_BOND);
    }

    /// @notice `encode` rejects a zero bond ceiling just as `decode` does.
    function test_encode_rejectsZeroMaxBondAmount() public {
        vm.expectRevert(HookDataCodec.ZeroMaxBondAmount.selector);

        this.callEncode(RECIPIENT, 0);
    }

    /// @dev Provides the external call boundary required by `vm.expectRevert` for the internal library encoder.
    function callEncode(address refundRecipient, uint128 maxBondAmount) external pure returns (bytes memory) {
        return HookDataCodec.encode(refundRecipient, maxBondAmount);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzzes the roundtrip property across every valid recipient and bond-ceiling value.

    /// @dev For all valid inputs:
    ///
    /// `decode(encode(refundRecipient, maxBondAmount)) == original values`
    function testFuzz_roundtrip(address refundRecipient, uint128 maxBondAmount) public view {
        vm.assume(refundRecipient != address(0));

        vm.assume(maxBondAmount != 0);

        bytes memory data = HookDataCodec.encode(refundRecipient, maxBondAmount);

        assertEq(data.length, HookDataCodec.ENCODED_LENGTH, "encoded length is not constant");

        (address decodedRecipient, uint128 decodedMaxBond) = harness.decode(data);

        assertEq(decodedRecipient, refundRecipient, "recipient not preserved");

        assertEq(decodedMaxBond, maxBondAmount, "maxBondAmount not preserved");
    }

    /// @notice Any payload with the supported version but the wrong total length must revert.

    /// @dev The valid version byte is prepended explicitly so this fuzz test reaches the length check rather than being rejected earlier by version validation.
    function testFuzz_wrongLengthAlwaysReverts(bytes calldata blob) public {
        // Adding the version byte produces a valid 37-byte payload only when
        // blob.length == 36, so exclude that one valid length.
        vm.assume(blob.length != HookDataCodec.ENCODED_LENGTH - 1);

        bytes memory data = abi.encodePacked(HookDataCodec.VERSION, blob);

        vm.expectRevert(
            abi.encodeWithSelector(
                HookDataCodec.InvalidHookDataLength.selector, HookDataCodec.ENCODED_LENGTH, data.length
            )
        );

        harness.decode(data);
    }

    /// @notice Any leading version byte other than the supported version is rejected regardless of the remaining bytes.
    /// @dev Includes version 1 in its domain, so the v1 rejection is fuzzed as well as pinned.
    function testFuzz_anyUnsupportedVersionReverts(uint8 version, bytes calldata tail) public {
        vm.assume(version != HookDataCodec.VERSION);

        bytes memory data = abi.encodePacked(version, tail);

        vm.expectRevert(abi.encodeWithSelector(HookDataCodec.UnsupportedHookDataVersion.selector, version));

        harness.decode(data);
    }

    /// @notice Fuzzes a full-length payload whose only defect is the version byte.
    /// @dev Complements `testFuzz_anyUnsupportedVersionReverts`, which fuzzes the tail too: here
    ///      the payload is otherwise perfectly valid, so the version byte is provably the only
    ///      reason it is rejected. Version 1 is inside the domain.
    function testFuzz_wellFormedPayloadWithWrongVersionReverts(
        uint8 version,
        address refundRecipient,
        uint128 maxBondAmount
    ) public {
        vm.assume(version != HookDataCodec.VERSION);
        vm.assume(refundRecipient != address(0));
        vm.assume(maxBondAmount != 0);

        bytes memory data = abi.encodePacked(version, refundRecipient, maxBondAmount);

        assertEq(data.length, HookDataCodec.ENCODED_LENGTH, "probe must be full length");

        vm.expectRevert(abi.encodeWithSelector(HookDataCodec.UnsupportedHookDataVersion.selector, version));

        harness.decode(data);
    }

    /*//////////////////////////////////////////////////////////////
                                  GAS
    //////////////////////////////////////////////////////////////*/

    /// @notice Measures the isolated cost of decoding valid hookData and keeps it below the configured regression ceiling.
    function test_decodeGas() public view {
        bytes memory data = HookDataCodec.encode(RECIPIENT, MAX_BOND);

        (uint256 gasUsed, address recipient, uint128 maxBond) = harness.decodeGas(data);

        assertEq(recipient, RECIPIENT);

        assertEq(maxBond, MAX_BOND);

        console2.log("HookDataCodec.decode gas (isolated):", gasUsed);

        assertLt(gasUsed, DECODE_GAS_CEILING, "decode gas regressed past its fence");
    }
}
