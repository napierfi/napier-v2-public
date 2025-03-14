// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";

import {Base} from "../../Base.t.sol";

import {AccessManager} from "src/modules/AccessManager.sol";
import {DefaultConnectorFactory} from "src/modules/connectors/DefaultConnectorFactory.sol";
import {VaultConnector} from "src/modules/connectors/VaultConnector.sol";
import {VaultConnectorRegistry} from "src/modules/connectors/VaultConnectorRegistry.sol";
import {Errors} from "src/Errors.sol";

contract VaultConnectorRegistryTest is Base {
    DefaultConnectorFactory defaultConnectorFactory;
    VaultConnectorRegistry registry;
    address weth = makeAddr("MockWETH");

    function setUp() public override {
        super.setUp();

        defaultConnectorFactory = new DefaultConnectorFactory(weth);
        registry = new VaultConnectorRegistry(napierAccessManager, address(defaultConnectorFactory));

        mockAccessManagerCanCall(dev, address(registry), registry.setConnector.selector, true);
    }

    function test_SetConnector() public {
        address target = makeAddr("target");
        address asset = makeAddr("asset");
        address connector = makeAddr("connector");
        vm.prank(dev);
        registry.setConnector(target, asset, VaultConnector(connector));
        assertEq(address(registry.getConnector(target, asset)), address(connector), "Connector not set");
    }

    function test_SetConnector_RevertWhen_NotAuthorized() public {
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        registry.setConnector(address(target), address(base), VaultConnector(address(0x2212)));
    }

    function test_getConnector() public {}

    function mockAccessManagerCanCall(address caller, address target, bytes4 selector, bool access) public {
        vm.mockCall(
            address(napierAccessManager),
            abi.encodeWithSelector(AccessManager.canCall.selector, caller, target, selector),
            abi.encode(access)
        );
    }
}
