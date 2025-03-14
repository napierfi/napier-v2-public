// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {CREATE3} from "solady/src/utils/CREATE3.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";

import {ERC4626Connector} from "./ERC4626Connector.sol";
import {VaultConnector} from "./VaultConnector.sol";

import {Errors} from "../../Errors.sol";

contract DefaultConnectorFactory {
    address internal immutable _i_WETH;

    constructor(address WETH) {
        _i_WETH = WETH;
    }

    function getOrCreateConnector(address target, address asset) public returns (VaultConnector) {
        (bool success, bytes memory result) = target.staticcall(abi.encodeWithSelector(ERC4626.asset.selector));
        if (!success || target.code.length == 0) revert Errors.DefaultConnectorFactory_TargetNotERC4626();
        if (asset != abi.decode(result, (address))) revert Errors.DefaultConnectorFactory_InvalidToken();

        bytes32 salt = bytes32(uint256(uint160(target)));
        address connectorAddress = CREATE3.predictDeterministicAddress(salt);

        if (connectorAddress.code.length == 0) {
            bytes memory creationCode =
                abi.encodePacked(type(ERC4626Connector).creationCode, abi.encode(target, _i_WETH));
            CREATE3.deployDeterministic(creationCode, salt);
        }

        return VaultConnector(connectorAddress);
    }
}
