// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {HookDataCodec} from "../src/libraries/HookDataCodec.sol";

contract HookDataCodecHarness {
    function encodeData(address refundRecipient, uint128 maxBondAmount) external pure returns (bytes memory) {
        return HookDataCodec.encode(refundRecipient, maxBondAmount);
    }

    function decodeData(bytes calldata data) external pure returns (address refundRecipient, uint128 maxBondAmount) {
        return HookDataCodec.decode(data);
    }
}

contract HookDataCodecTest is Test {
    HookDataCodecHarness internal harness;

    function setUp() public {
        harness = new HookDataCodecHarness();
    }

    function test_encodeDecode_fixed37BytePayload() public view {
        address recipient = address(0xBEEF);
        uint128 maxBond = 123456789;
        bytes memory data = harness.encodeData(recipient, maxBond);

        assertEq(data.length, 37);
        (address decodedRecipient, uint128 decodedMaxBond) = harness.decodeData(data);
        assertEq(decodedRecipient, recipient);
        assertEq(decodedMaxBond, maxBond);
    }

    function test_decode_rejectsEmptyPayload() public {
        vm.expectRevert(HookDataCodec.InvalidHookDataLength.selector);
        harness.decodeData("");
    }

    function test_decode_rejectsShortPayload() public {
        vm.expectRevert(HookDataCodec.InvalidHookDataLength.selector);
        harness.decodeData(new bytes(36));
    }

    function test_decode_rejectsLongPayload() public {
        vm.expectRevert(HookDataCodec.InvalidHookDataLength.selector);
        harness.decodeData(new bytes(38));
    }

    function test_decode_rejectsUnknownVersion() public {
        bytes memory data = harness.encodeData(address(0xBEEF), 1);
        data[0] = bytes1(uint8(2));

        vm.expectRevert(HookDataCodec.InvalidHookDataVersion.selector);
        harness.decodeData(data);
    }

    function test_decode_rejectsZeroRefundRecipient() public {
        bytes memory data = abi.encodePacked(bytes1(uint8(1)), address(0), uint128(1));

        vm.expectRevert(HookDataCodec.InvalidRefundRecipient.selector);
        harness.decodeData(data);
    }

    function test_decode_rejectsZeroMaximumBond() public {
        bytes memory data = abi.encodePacked(bytes1(uint8(1)), address(0xBEEF), uint128(0));

        vm.expectRevert(HookDataCodec.InvalidMaxBondAmount.selector);
        harness.decodeData(data);
    }

    function test_encode_rejectsZeroRefundRecipient() public {
        vm.expectRevert(HookDataCodec.InvalidRefundRecipient.selector);
        harness.encodeData(address(0), 1);
    }

    function test_encode_rejectsZeroMaximumBond() public {
        vm.expectRevert(HookDataCodec.InvalidMaxBondAmount.selector);
        harness.encodeData(address(0xBEEF), 0);
    }

    function testFuzz_encodeDecode_roundTrips(address recipient, uint128 maxBond) public view {
        vm.assume(recipient != address(0));
        vm.assume(maxBond != 0);

        bytes memory data = harness.encodeData(recipient, maxBond);
        (address decodedRecipient, uint128 decodedMaxBond) = harness.decodeData(data);
        assertEq(decodedRecipient, recipient);
        assertEq(decodedMaxBond, maxBond);
    }
}
