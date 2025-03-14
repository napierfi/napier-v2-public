// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";
import {ZapBase} from "../../Base.t.sol";

import {WrapperFactory} from "src/wrapper/WrapperFactory.sol";
import {ERC4626WrapperConnector} from "src/modules/connectors/ERC4626WrapperConnector.sol";
import {MockWrapper} from "../../mocks/MockWrapper.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

contract WrapperFactoryTest is ZapBase {
    address s_wrapperImplementation;
    address s_connectorImplementation;
    WrapperFactory s_wcfactory;

    function setUp() public override {
        super.setUp();
        _deployPeriphery(); // Deploy VaultConnectorRegistry

        s_wrapperImplementation = address(new MockWrapper());
        s_connectorImplementation = address(new ERC4626WrapperConnector());

        s_wcfactory = new WrapperFactory(address(napierAccessManager), address(weth), address(connectorRegistry));

        vm.label(address(s_connectorImplementation), "connectorImplementation");
        vm.label(address(s_wrapperImplementation), "wrapperImplementation");

        vm.startPrank(admin);
        // Set up access to WrapperFactory
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = WrapperFactory.setWrapperImplementation.selector;
        selectors[1] = WrapperFactory.setConnectorImplementation.selector;
        selectors[2] = WrapperFactory.setVaultConnectorRegistry.selector;
        selectors[3] = WrapperFactory.createWrapper.selector;
        napierAccessManager.grantTargetFunctionRoles(address(s_wcfactory), selectors, Constants.DEV_ROLE);

        s_wcfactory.setWrapperImplementation(s_wrapperImplementation, true);
        s_wcfactory.setVaultConnectorRegistry(address(connectorRegistry));

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
        vm.prank(admin);
        s_wcfactory.createWrapper(s_wrapperImplementation, args);
    }

    function test_CreateWrapper_RevertWhen_NotAuthorized() public {
        bytes memory args = abi.encode(target, weth);
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        s_wcfactory.createWrapper(s_wrapperImplementation, args);
    }

    function test_CreateWrapper_RevertWhen_InvalidImplementation() public {
        vm.startPrank(admin);
        vm.expectRevert(Errors.WrapperFactory_ImplementationNotSet.selector);
        s_wcfactory.createWrapper(makeAddr("invalidImplementation"), abi.encode("junk"));
    }

    function test_SetImplementation_RevertWhen_NotAuthorized() public {
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        s_wcfactory.setConnectorImplementation(s_connectorImplementation);

        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        s_wcfactory.setWrapperImplementation(s_wrapperImplementation, true);
    }

    function test_SetVaultConnectorRegistry_RevertWhen_NotAuthorized() public {
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        s_wcfactory.setVaultConnectorRegistry(address(connectorRegistry));
    }
}
