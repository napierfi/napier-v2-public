// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";

import {AccessManager} from "src/modules/AccessManager.sol";
import {DefaultConnectorFactory} from "src/modules/connectors/DefaultConnectorFactory.sol";
import {VaultConnector} from "src/modules/connectors/VaultConnector.sol";
import {VaultConnectorRegistry} from "src/modules/connectors/VaultConnectorRegistry.sol";
import {Errors} from "src/Errors.sol";

contract Dummy {}

contract VaultConnectorRegistryTest is Test {
    DefaultConnectorFactory defaultConnectorFactory;
    VaultConnectorRegistry registry;
    address weth = makeAddr("MockWETH");
    address dev = makeAddr("dev");
    address napierAccessManager = address(new Dummy());
    address target = makeAddr("target");
    address asset = makeAddr("asset");

    function setUp() public {
        defaultConnectorFactory = new DefaultConnectorFactory(weth);
        registry = new VaultConnectorRegistry(AccessManager(napierAccessManager), address(defaultConnectorFactory));

        mockAccessManagerCanCall(dev, address(registry), registry.setConnector.selector, true);
    }

    function test_SetConnector() public {
        address connector = makeAddr("connector");
        vm.prank(dev);
        registry.setConnector(target, asset, VaultConnector(connector));
        assertEq(address(registry.getConnector(target, asset)), address(connector), "Connector not set");
    }

    function test_SetConnector_RevertWhen_NotAuthorized() public {
        mockAccessManagerCanCall(dev, address(registry), registry.setConnector.selector, false);
        vm.prank(dev);
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        registry.setConnector(target, asset, VaultConnector(address(0x2212)));
    }

    function test_getConnector() public {}

    function mockAccessManagerCanCall(address caller, address _target, bytes4 selector, bool access) public {
        vm.mockCall(
            address(napierAccessManager),
            abi.encodeWithSelector(AccessManager.canCall.selector, caller, _target, selector),
            abi.encode(access)
        );
    }
}
