// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {PrincipalTokenTest} from "../shared/PrincipalToken.t.sol";

import "src/Constants.sol" as Constants;
import {Errors} from "src/Errors.sol";

contract PauseTest is PrincipalTokenTest {
    function setUp() public override {
        super.setUp();

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = principalToken.pause.selector;
        selectors[1] = principalToken.unpause.selector;
        _grantRoles({account: dev, roles: Constants.DEV_ROLE, callee: address(principalToken), selectors: selectors});
    }

    function test_PauseUnPause() public {
        assertFalse(principalToken.paused());

        vm.prank(dev);
        principalToken.pause();

        assertTrue(principalToken.paused());

        vm.prank(dev);
        principalToken.unpause();

        assertFalse(principalToken.paused());
    }

    function test_RevertWhen_NotAuthorized() public {
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        vm.prank(alice);
        principalToken.pause();

        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        vm.prank(alice);
        principalToken.unpause();
    }

    function test_RevertWhen_OwnershipRenounced() public {
        vm.prank(curator);
        accessManager.renounceOwnership();

        vm.expectRevert(Errors.PrincipalToken_Unstoppable.selector);
        vm.prank(dev);
        principalToken.pause();
    }
}
