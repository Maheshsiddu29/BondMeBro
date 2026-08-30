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

    /// @notice Verifies that version 1 is exactly 37 bytes and places the version byte at offset 0.

    /// @dev A roundtrip alone is not enough to protect a wire format because `encode` and `decode` could change together and still pass. These assertions pin the external byte-level format.
    function test_wireFormat_versionByteIsFirst() public pure {
        bytes memory data = HookDataCodec.encode(RECIPIENT, MAX_BOND);

        assertEq(data.length, HookDataCodec.ENCODED_LENGTH, "payload is not 37 bytes");

        assertEq(uint8(data[0]), HookDataCodec.VERSION, "version byte is not at offset 0");

        assertEq(HookDataCodec.ENCODED_LENGTH, 37, "ENCODED_LENGTH drifted from 1 + 20 + 16");
    }

    /// @notice Verifies the exact packed position of every version 1 field.
    function test_wireFormat_fieldOffsets() public view {
        address recipient = address(0x00112233445566778899AABbCCdDeeFf00112233);

        uint128 maxBond = 0x0123456789ABCDEF0123456789ABCDEF;

        bytes memory data = HookDataCodec.encode(recipient, maxBond);

        assertEq(data, abi.encodePacked(uint8(1), recipient, maxBond), "packed layout changed");

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

    /*//////////////////////////////////////////////////////////////
                         MALFORMED — DECODE
    //////////////////////////////////////////////////////////////*/

    /// @notice Empty hookData is rejected with `MissingHookData`.
    function test_empty_reverts() public {
        vm.expectRevert(HookDataCodec.MissingHookData.selector);

        harness.decode("");
    }

    /// @notice Every truncated version 1 payload is rejected.
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

    /// @notice Payloads longer than the exact version 1 length are rejected rather than having trailing bytes ignored.
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

    /// @dev `abi.encode(uint8, address, uint128)` produces three 32-byte words. The `uint8` is right-aligned inside the first word, so byte 0 is zero rather than version 1. Because the codec reads the version before checking length, the error clearly identifies the schema mismatch.
    function test_abiEncodedPayload_revertsAsWrongVersion() public {
        bytes memory abiEncoded = abi.encode(uint8(1), RECIPIENT, MAX_BOND);

        assertEq(abiEncoded.length, 96, "sanity: abi.encode of these three fields is 96 bytes");

        assertEq(uint8(abiEncoded[0]), 0, "sanity: abi.encode leaves byte 0 as padding");

        vm.expectRevert(abi.encodeWithSelector(HookDataCodec.UnsupportedHookDataVersion.selector, uint8(0)));

        harness.decode(abiEncoded);
    }

    /// @notice An unsupported non-zero schema version is rejected.
    function test_wrongVersion_reverts() public {
        bytes memory data = abi.encodePacked(uint8(2), RECIPIENT, MAX_BOND);

        vm.expectRevert(abi.encodeWithSelector(HookDataCodec.UnsupportedHookDataVersion.selector, uint8(2)));

        harness.decode(data);
    }

    /// @notice Version zero is not treated as a valid version 1 payload.
    function test_versionZero_reverts() public {
        bytes memory data = abi.encodePacked(uint8(0), RECIPIENT, MAX_BOND);

        vm.expectRevert(abi.encodeWithSelector(HookDataCodec.UnsupportedHookDataVersion.selector, uint8(0)));

        harness.decode(data);
    }

    /// @notice Version validation happens before version 1 length validation.

    /// @dev A future payload with a different version and different size should be reported as unsupported rather than incorrectly reported as malformed version 1 data.
    function test_wrongVersion_isCheckedBeforeLength() public {
        bytes memory shortV2 = abi.encodePacked(uint8(2), bytes4(0xDEADBEEF));

        vm.expectRevert(abi.encodeWithSelector(HookDataCodec.UnsupportedHookDataVersion.selector, uint8(2)));

        harness.decode(shortV2);
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

    /// @notice Any payload with version 1 but the wrong total length must revert.

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
    function testFuzz_anyNonOneVersionReverts(uint8 version, bytes calldata tail) public {
        vm.assume(version != HookDataCodec.VERSION);

        bytes memory data = abi.encodePacked(version, tail);

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
