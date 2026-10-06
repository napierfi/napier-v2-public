// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";
import {TwoCryptoZapBase} from "../../TwoCryptoBase.t.sol";
import {WrapperFactory} from "src/wrapper/WrapperFactory.sol";
import {WrapperConnector} from "src/modules/connectors/WrapperConnector.sol";
import {MockWrapper} from "../../mocks/MockWrapper.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

contract WrapperFactoryTest is TwoCryptoZapBase {
    address s_wrapperImplementation;
    address s_connectorImplementation;
    WrapperFactory s_wcfactory;

    function setUp() public override {
        super.setUp();
        _deployPeriphery(); // Deploy VaultConnectorRegistry

        s_wrapperImplementation = address(new MockWrapper());
        s_connectorImplementation = address(new WrapperConnector());

        s_wcfactory = new WrapperFactory(
            address(napierAccessManager), address(weth), address(connectorRegistry), s_connectorImplementation
        );

        vm.label(address(s_connectorImplementation), "connectorImplementation");
        vm.label(address(s_wrapperImplementation), "wrapperImplementation");

        vm.startPrank(admin);
        // Set up access to WrapperFactory
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = WrapperFactory.setVaultConnectorRegistry.selector;
        selectors[1] = WrapperFactory.setConnectorImplementation.selector;
        selectors[1] = WrapperFactory.createWrapper.selector;
        selectors[2] = WrapperFactory.setWrapperImplementation.selector;
        napierAccessManager.grantTargetFunctionRoles(address(s_wcfactory), selectors, Constants.DEV_ROLE);

        s_wcfactory.setVaultConnectorRegistry(address(connectorRegistry));
        s_wcfactory.setWrapperImplementation(s_wrapperImplementation, true);

        // Set up access to VaultConnectorRegistry by WrapperFactory
        bytes4[] memory selectors2 = new bytes4[](1);
        selectors2[0] = connectorRegistry.setConnector.selector;
        napierAccessManager.grantTargetFunctionRoles(
            address(connectorRegistry), selectors2, Constants.CONNECTOR_REGISTRY_ROLE
        );
        napierAccessManager.grantRoles(address(s_wcfactory), Constants.CONNECTOR_REGISTRY_ROLE);

        vm.stopPrank();
    }

    function test_CreateWrapper() public {
        bytes memory args = abi.encode(target, weth);
        bytes32 salt = bytes32(uint256(123));

        // Pre-calculate expected wrapper address
        address expectedWrapper =
            LibClone.predictDeterministicAddress(s_wrapperImplementation, args, salt, address(s_wcfactory));

        // Deploy wrapper
        vm.prank(alice);
        address actualWrapper = s_wcfactory.createWrapper(s_wrapperImplementation, args, salt);

        // Assert deterministic deployment
        assertEq(actualWrapper, expectedWrapper, "Wrapper address should be deterministic");
        assertEq(address(s_wcfactory.s_wrappers(actualWrapper)), s_wrapperImplementation);
    }

    function test_CreateWrapper_RevertWhen_InvalidWrapperImplementation() public {
        bytes memory args = abi.encode(target, weth);
        bytes32 salt = bytes32(uint256(123));
        vm.expectRevert(Errors.WrapperFactory_InvalidWrapperImplementation.selector);
        s_wcfactory.createWrapper(address(0xcafe), args, salt);
    }

    function test_SetImplementation_RevertWhen_NotAuthorized() public {
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        s_wcfactory.setConnectorImplementation(s_connectorImplementation);
    }

    function test_SetVaultConnectorRegistry() public {
        address newConnectorRegistry = address(0xcafe);
        address previousRegistry = address(s_wcfactory.s_vaultConnectorRegistry());
        vm.expectEmit(true, true, false, false, address(s_wcfactory));
        emit WrapperFactory.SetVaultConnectorRegistry(previousRegistry, newConnectorRegistry);
        vm.prank(admin);
        s_wcfactory.setVaultConnectorRegistry(newConnectorRegistry);
        assertEq(address(s_wcfactory.s_vaultConnectorRegistry()), newConnectorRegistry);
    }

    function test_SetWrapperImplementation() public {
        vm.prank(admin);
        s_wcfactory.setWrapperImplementation(address(0xbabe), true);
        assertEq(s_wcfactory.s_wrapperImplementations(address(0xbabe)), true);
    }

    function test_SetVaultConnectorRegistry_RevertWhen_NotAuthorized() public {
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        s_wcfactory.setVaultConnectorRegistry(address(connectorRegistry));
    }

    function test_SetWrapperImplementation_RevertWhen_NotAuthorized() public {
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        s_wcfactory.setWrapperImplementation(address(0xbabe), true);
    }
}
