// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {VaultConnector} from "./VaultConnector.sol";
import {DefaultConnectorFactory} from "./DefaultConnectorFactory.sol";

import {AccessManaged, AccessManager} from "../AccessManager.sol";

contract VaultConnectorRegistry is AccessManaged {
    AccessManager private immutable _i_accessManager;
    DefaultConnectorFactory public immutable _i_defaultConnector;

    mapping(address target => mapping(address asset => VaultConnector)) public s_connectors;

    constructor(AccessManager accessManager, address defaultConnector) {
        _i_accessManager = accessManager;
        _i_defaultConnector = DefaultConnectorFactory(defaultConnector);
    }

    function getConnector(address target, address asset) public returns (VaultConnector) {
        VaultConnector connector = s_connectors[target][asset];
        return address(connector) == address(0) ? _i_defaultConnector.getOrCreateConnector(target, asset) : connector;
    }

    function setConnector(address target, address asset, VaultConnector connector) public restricted {
        s_connectors[target][asset] = connector;
    }

    function i_accessManager() public view override returns (AccessManager) {
        return _i_accessManager;
    }
}
