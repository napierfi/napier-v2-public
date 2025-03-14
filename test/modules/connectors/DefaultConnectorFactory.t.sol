// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";

import {CREATE3} from "solady/src/utils/CREATE3.sol";

import {DefaultConnectorFactory} from "src/modules/connectors/DefaultConnectorFactory.sol";
import {VaultConnector} from "src/modules/connectors/VaultConnector.sol";
import {ERC4626Connector} from "src/modules/connectors/ERC4626Connector.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockWETH} from "../../mocks/MockWETH.sol";
import {Errors} from "src/Errors.sol";

contract MockERC4626 {
    address _i_asset;

    constructor(address _asset) {
        _i_asset = _asset;
    }

    function asset() public view returns (address) {
        return _i_asset;
    }
}

contract DefaultConnectorFactoryTest is Test {
    DefaultConnectorFactory factory;
    address mockTarget;
    MockERC20 asset;
    MockWETH weth;

    function setUp() public {
        asset = new MockERC20(18);
        mockTarget = address(new MockERC4626(address(asset)));
        weth = new MockWETH();
        factory = new DefaultConnectorFactory(address(weth));
    }

    function test_getOrCreateConnector() public {
        // First call should create a new connector
        VaultConnector connector = factory.getOrCreateConnector(mockTarget, address(asset));

        // Verify the connector address
        bytes32 salt = bytes32(uint256(uint160(mockTarget)));
        address expectedAddress = CREATE3.predictDeterministicAddress(salt, address(factory));
        assertEq(address(connector), expectedAddress, "Connector address mismatch");

        // Verify the connector's target
        assertEq(address(connector.target()), mockTarget, "Connector target mismatch");

        // Second call should return the existing connector
        VaultConnector sameConnector = factory.getOrCreateConnector(mockTarget, address(asset));
        assertEq(address(sameConnector), address(connector), "Should return the same connector");
    }

    function test_getOrCreateConnector_DifferentTargets() public {
        address anotherTarget = address(new MockERC4626(address(asset)));
        VaultConnector connector1 = factory.getOrCreateConnector(mockTarget, address(asset));
        VaultConnector connector2 = factory.getOrCreateConnector(anotherTarget, address(asset));

        assertFalse(address(connector1) == address(connector2), "Connectors for different targets should be different");
        assertEq(address(connector1.target()), mockTarget, "First connector target mismatch");
        assertEq(address(connector2.target()), anotherTarget, "Second connector target mismatch");
    }

    function test_getOrCreateConnector_TargetNotContract() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.DefaultConnectorFactory_TargetNotERC4626.selector));
        factory.getOrCreateConnector(address(0), address(asset));
    }

    function test_getOrCreateConnector_InvalidToken() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.DefaultConnectorFactory_InvalidToken.selector));
        factory.getOrCreateConnector(mockTarget, address(0));
    }
}
