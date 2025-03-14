// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {ZapPrincipalTokenTest} from "../shared/Zap.t.sol";

import {Errors} from "src/Errors.sol";

contract HookValidationTest is ZapPrincipalTokenTest {
    function testFuzz_RevertWhen_OnSupply(uint256[2] memory values, bytes memory data) public {
        vm.expectRevert(Errors.Zap_BadCallback.selector);
        zap.onSupply(values[0], values[1], data);
    }

    function testFuzz_RevertWhen_OnUnite(uint256[2] memory values, bytes memory data) public {
        vm.expectRevert(Errors.Zap_BadCallback.selector);
        zap.onUnite(values[0], values[1], data);
    }
}
