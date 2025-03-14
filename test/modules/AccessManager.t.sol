// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {AccessManager} from "src/modules/AccessManager.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

contract AccessManagerTest is Test {
    uint256 constant _ROLE_0 = 1 << 0;
    uint256 constant _ROLE_1 = 1 << 1;
    uint256 constant _ROLE_2 = 1 << 2;

    AccessManager accessManagerImplementation;
    AccessManager accessManager;
    address owner;
    address user;
    address delegatee;
    address mockTarget;
    bytes4 mockSelector;

    error Unauthorized(); // OwnableRoles.sol from solady

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");
        delegatee = makeAddr("delegatee");
        mockTarget = makeAddr("mockTarget");
        mockSelector = bytes4(keccak256("mockFunction()"));

        // Deploy the AccessManager implementation
        accessManagerImplementation = new AccessManager();

        // Deploy the AccessManager instance using LibClone
        bytes memory encodedArgs = abi.encode(owner);
        address accessManagerAddress = LibClone.clone(address(accessManagerImplementation), encodedArgs);
        accessManager = AccessManager(accessManagerAddress);
        accessManager.initializeOwner(owner);
    }

    function test_InitialOwner() public view {
        assertEq(accessManager.owner(), owner, "Incorrect initial owner");
    }

    function test_GrantTargetFunctionRole() public {
        uint256 roles = 1;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = mockSelector;

        vm.startPrank(owner);
        accessManager.grantRoles(user, roles);
        accessManager.grantTargetFunctionRoles(mockTarget, selectors, roles);
        vm.stopPrank();

        assertTrue(accessManager.canCall(user, mockTarget, mockSelector), "Role not granted correctly");
    }

    function test_RevokeTargetFunctionRole() public {
        uint256 roles = 1;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = mockSelector;

        vm.startPrank(owner);
        accessManager.grantRoles(user, roles);
        accessManager.grantTargetFunctionRoles(mockTarget, selectors, roles);
        accessManager.revokeTargetFunctionRoles(mockTarget, selectors, roles);
        vm.stopPrank();

        assertFalse(accessManager.canCall(user, mockTarget, mockSelector), "Role not revoked correctly");
    }

    function test_RevertWhen_UnauthorizedGrantRole() public {
        uint256 roles = 1;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = mockSelector;

        vm.startPrank(user);
        vm.expectRevert(Unauthorized.selector);
        accessManager.grantTargetFunctionRoles(mockTarget, selectors, roles);
        vm.stopPrank();
    }

    function test_RevertWhen_UnauthorizedRevokeRole() public {
        uint256 roles = 1;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = mockSelector;

        vm.startPrank(user);
        vm.expectRevert(Unauthorized.selector);
        accessManager.revokeTargetFunctionRoles(mockTarget, selectors, roles);
        vm.stopPrank();
    }

    function test_MultipleRoles() public {
        uint256 role1 = 1; // bit 0001
        uint256 role2 = 2; // bit 0010
        uint256 roles = role1 | role2;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = mockSelector;

        vm.startPrank(owner);
        accessManager.grantRoles(user, roles);
        accessManager.grantTargetFunctionRoles(mockTarget, selectors, roles);
        vm.stopPrank();

        assertTrue(accessManager.canCall(user, mockTarget, mockSelector), "Multiple roles not granted correctly");

        vm.prank(owner);
        accessManager.revokeTargetFunctionRoles(mockTarget, selectors, role1);

        assertTrue(accessManager.canCall(user, mockTarget, mockSelector), "Role2 should still be active");

        vm.prank(owner);
        accessManager.revokeTargetFunctionRoles(mockTarget, selectors, role2);

        assertFalse(accessManager.canCall(user, mockTarget, mockSelector), "All roles should be revoked");
    }

    function test_CanCallWithoutRole() public view {
        assertFalse(accessManager.canCall(user, mockTarget, mockSelector), "Should not be able to call without role");
    }

    function test_DelegateeCanCall() public {
        uint256 roles = _ROLE_0 | _ROLE_1 | _ROLE_2;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = accessManager.grantTargetFunctionRoles.selector;

        // grant access to accessManager itself
        vm.startPrank(owner);
        accessManager.grantRoles(delegatee, roles);
        accessManager.grantTargetFunctionRoles(address(accessManager), selectors, roles);
        vm.stopPrank();

        bytes4[] memory mockSelectors = new bytes4[](1);
        mockSelectors[0] = mockSelector;

        vm.startPrank(delegatee);
        accessManager.grantTargetFunctionRoles(mockTarget, mockSelectors, 111); // should be allowed

        vm.expectRevert(Unauthorized.selector);
        accessManager.grantRoles(delegatee, 99999); // should not be allowed
        vm.stopPrank();
    }

    function test_RevertWhen_ReinitializeOwner() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        accessManager.initializeOwner(user);
    }

    function test_Multicall() public {
        uint256 roles = _ROLE_0 | _ROLE_2;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = accessManager.revokeTargetFunctionRoles.selector;

        vm.startPrank(owner);
        bytes[] memory grantCalls = new bytes[](2);
        grantCalls[0] = abi.encodeCall(accessManager.grantRoles, (delegatee, roles));
        grantCalls[1] =
            abi.encodeCall(accessManager.grantTargetFunctionRoles, (address(accessManager), selectors, roles));
        accessManager.multicall(grantCalls);
        vm.stopPrank();

        assertTrue(accessManager.canCall(delegatee, address(accessManager), selectors[0]), "Role not granted correctly");

        vm.startPrank(delegatee);
        bytes[] memory revokeCalls = new bytes[](1);
        revokeCalls[0] =
            abi.encodeCall(accessManager.revokeTargetFunctionRoles, (address(accessManager), selectors, roles));
        accessManager.multicall(revokeCalls);
        vm.stopPrank();
        assertFalse(
            accessManager.canCall(delegatee, address(accessManager), selectors[0]), "Role not revoked correctly"
        );
    }
}
