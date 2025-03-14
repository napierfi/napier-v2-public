// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {LibExpiry} from "src/utils/LibExpiry.sol";
import {EIP5095} from "src/interfaces/EIP5095.sol";

contract Dummy {}

contract LibExpiryTest is Test {
    EIP5095 dummy;

    function setUp() public {
        dummy = EIP5095(address(new Dummy()));
    }

    function testFuzz_Expiry(uint256 expiry) public {
        vm.mockCall(address(dummy), abi.encodeWithSelector(EIP5095.maturity.selector), abi.encode(expiry));

        assertEq(LibExpiry.isExpired(expiry), block.timestamp >= expiry, "isExpired");
        assertEq(LibExpiry.isExpired(expiry), LibExpiry.isExpired(dummy), "isExpired==isExpired");
        assertEq(LibExpiry.isExpired(expiry), !LibExpiry.isNotExpired(dummy), "isExpired != isNotExpired");
    }
}
