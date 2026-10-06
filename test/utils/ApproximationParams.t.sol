// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";

import {LibBytes} from "solady/src/utils/LibBytes.sol";

import "src/types/ApproximationParams.sol";
import "src/Errors.sol";

contract ApproximationParamsTest is Test {
    function getStructSize() public pure returns (uint256) {
        ApproximationParams memory params;
        return abi.encode(params).length;
    }

    function testFuzz_DecodeZeroLength(bytes calldata encoded) public pure {
        vm.assume(encoded.length == 0);

        (int256 guessMin, int256 guessMax, uint256 eps) = decodeApproximationParams(encoded);

        assertEq(guessMin, 0, "guessMin should be 0");
        assertEq(guessMax, 0, "guessMax should be 0");
        assertEq(eps, 0, "eps should be 0");
    }

    function testFuzz_Decode(ApproximationParams calldata params) public view {
        this._test_Decode(abi.encode(params));
        this._test_Decode(abi.encode(params, vm.randomBytes(0x20)));
    }

    function _test_Decode(bytes calldata encoded) public pure {
        (int256 guessMin, int256 guessMax, uint256 eps) = decodeApproximationParams(encoded);

        assertEq(guessMin, int256(uint256(bytes32(encoded[0:0x20]))), "guessMin");
        assertEq(guessMax, int256(uint256(bytes32(encoded[0x20:0x40]))), "guessMax");
        assertEq(eps, uint256(bytes32(encoded[0x40:0x60])), "eps");

        ApproximationParams memory params = decodeApproximationParamsStruct(encoded);
        ApproximationParams memory decoded = abi.decode(encoded, (ApproximationParams));

        assertEq(params.guessMin, decoded.guessMin, "guessMin");
        assertEq(params.guessMax, decoded.guessMax, "guessMax");
        assertEq(params.eps, decoded.eps, "eps");
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testFuzz_RevertWhen_InvalidLength(bytes calldata encoded) public {
        vm.assume(encoded.length > 0 && encoded.length < getStructSize());

        vm.expectRevert(Errors.ApproximationParams_OutOfBounds.selector);
        decodeApproximationParams(encoded);
    }
}
