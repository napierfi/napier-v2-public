// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TokiQuoterTest} from "./TokiQuoter.t.sol";

import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";
import {TokiQuoter} from "src/lens/uniswap/TokiQuoter.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

contract UpgradeQuoterTest is TokiQuoterTest {
    function test_Upgrade_RevertWhen_NotAuthorized() public {
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        UUPSUpgradeable(address(quoter)).upgradeToAndCall(address(0xfafe), "");
    }

    function test_Upgrade() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = UUPSUpgradeable.upgradeToAndCall.selector;
        _grantRoles(napierAccessManager, admin, admin, address(quoter), selectors, Constants.DEV_ROLE);

        address newImplementation = address(new TokiQuoter());
        vm.prank(admin);
        UUPSUpgradeable(address(quoter)).upgradeToAndCall(newImplementation, "");

        (, bytes memory returnData) = address(quoter).call("c");
        assertEq(abi.decode(returnData, (address)), newImplementation);
    }
}
