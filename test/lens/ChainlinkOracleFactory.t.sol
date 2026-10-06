// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/src/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {MockFactory} from "../mocks/MockFactory.sol";

import {ChainlinkOracleFactory} from "src/oracles/chainlink/ChainlinkOracleFactory.sol";
import {AccessManager} from "src/modules/AccessManager.sol";
import {Factory} from "src/Factory.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

/// @dev Minimal dummy oracle implementation to be cloned.
contract Dummy {
    function initialize(bytes calldata) external {}
}

/// Phase 1: Foundation tests for ChainlinkOracleFactory
contract ChainlinkOracleFactoryTest is Test {
    address dummyFactory;
    AccessManager accessManager;

    address implementation;
    ChainlinkOracleFactory oracleFactory;

    address admin = makeAddr("admin");

    function setUp() public {
        // Provide a functional AccessManager via mocked oracleFactory call so `restricted` works deterministically.
        accessManager = new AccessManager();
        accessManager.initializeOwner(address(this));
        dummyFactory = address(new MockFactory(address(accessManager)));

        implementation = address(new Dummy());
        oracleFactory = new ChainlinkOracleFactory(Factory(dummyFactory));

        // ChainlinkOracleFactory.i_accessManager() calls `i_factory.i_accessManager()`.
        bytes memory callData = abi.encodeWithSelector(Factory.i_accessManager.selector);
        vm.mockCall(dummyFactory, callData, abi.encode(address(accessManager)));
    }

    function test_clone_succeeds_whenApproved() public {
        // Arrange: grant permission and pre-approve the implementation via AccessManager
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ChainlinkOracleFactory.setImplementation.selector;
        accessManager.grantRoles(address(this), Constants.DEV_ROLE);
        accessManager.grantTargetFunctionRoles(address(oracleFactory), selectors, Constants.DEV_ROLE);
        oracleFactory.setImplementation(implementation, true);

        bytes memory payload = abi.encode(address(0xAAA1), address(0xBBB2), uint256(1234));

        // Act
        address clone = oracleFactory.clone(implementation, payload, hex"");

        assertTrue(clone != address(0), "clone address should be nonzero");
        bytes memory stored = LibClone.argsOnClone(clone);
        assertEq(keccak256(stored), keccak256(payload), "immutable args payload mismatch");
    }

    function test_clone_reverts_whenNotApproved() public {
        vm.expectRevert(ChainlinkOracleFactory.ChainlinkOracleFactory_ImplementationNotDeployed.selector);
        oracleFactory.clone(implementation, hex"", hex"");
    }

    function test_setImplementation() public {
        accessManager.grantRoles(admin, Constants.DEV_ROLE);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ChainlinkOracleFactory.setImplementation.selector;
        accessManager.grantTargetFunctionRoles(address(oracleFactory), selectors, Constants.DEV_ROLE);

        address newImplementation = makeAddr("implementation");

        vm.startPrank(admin);
        oracleFactory.setImplementation(newImplementation, true);
        assertTrue(oracleFactory.s_implementations(newImplementation));

        oracleFactory.setImplementation(newImplementation, false);
        assertFalse(oracleFactory.s_implementations(newImplementation));
        vm.stopPrank();
    }

    function test_setImplementation_RevertWhen_NotAuthorized() public {
        // No roles granted; should revert with access error through AccessManager
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        oracleFactory.setImplementation(implementation, true);
    }
}
