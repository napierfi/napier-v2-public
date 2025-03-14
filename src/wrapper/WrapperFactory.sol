// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {LibClone} from "solady/src/utils/LibClone.sol";

import {VaultConnectorRegistry} from "../modules/connectors/VaultConnectorRegistry.sol";
import {StandardERC4626Wrapper} from "./StandardERC4626Wrapper.sol";
import {ERC4626WrapperConnector} from "../modules/connectors/ERC4626WrapperConnector.sol";

import "../Errors.sol";
import {AccessManager, AccessManaged} from "../modules/AccessManager.sol";

/// @title WrapperFactory
/// @notice Factory for creating Napier ERC4626 wrappers and connectors
contract WrapperFactory is AccessManaged {
    address private immutable _i_accessManager;
    address private immutable _i_weth;

    /// @notice The registry of vault connectors
    VaultConnectorRegistry public s_vaultConnectorRegistry;

    /// @notice The implementation of connector for standard ERC4626 wrapper
    address public s_connectorImplementation;

    /// @notice ERC4626 Wrapper implementation => valid
    mapping(address implementation => bool valid) public s_implementations;

    /// @notice ERC4626 Wrapper instance => implementation
    mapping(address wrapper => address implementation) public s_wrappers;

    event SetWrapperImplementation(address indexed implementation, bool valid);
    event SetConnectorImplementation(address indexed implementation);
    event WrapperCreated(address indexed wrapper, address indexed connector);

    constructor(address accessManager, address weth, address vaultConnectorRegistry) {
        _i_accessManager = accessManager;
        _i_weth = weth;
        s_vaultConnectorRegistry = VaultConnectorRegistry(vaultConnectorRegistry);
    }

    function setConnectorImplementation(address implementation) external restricted {
        s_connectorImplementation = implementation;
        emit SetConnectorImplementation(implementation);
    }

    function setWrapperImplementation(address implementation, bool valid) external restricted {
        s_implementations[implementation] = valid;
        emit SetWrapperImplementation(implementation, valid);
    }

    function setVaultConnectorRegistry(address _vaultConnectorRegistry) external restricted {
        s_vaultConnectorRegistry = VaultConnectorRegistry(_vaultConnectorRegistry);
    }

    /// @notice Create a new ERC4626 Wrapper and connector
    /// @dev Access to this function must be granted to the caller by the `AccessManager`
    /// @dev Access to `VaultConnectorRegistry.setConnector()` must be granted to this contract by the `AccessManager`
    /// @param wrapperImplementation The implementation to use for the wrapper
    /// @param args The immutable args for the wrapper
    /// @return The address of the new wrapper
    function createWrapper(address wrapperImplementation, bytes memory args) external restricted returns (address) {
        if (!s_implementations[wrapperImplementation]) revert Errors.WrapperFactory_ImplementationNotSet();

        address wrapper = LibClone.clone({implementation: wrapperImplementation, args: args});
        StandardERC4626Wrapper(wrapper).initialize();

        address connector =
            LibClone.clone({implementation: s_connectorImplementation, args: abi.encode(wrapper, _i_weth)});

        s_wrappers[wrapper] = wrapperImplementation;

        s_vaultConnectorRegistry.setConnector({
            target: wrapper,
            asset: StandardERC4626Wrapper(wrapper).asset(),
            connector: ERC4626WrapperConnector(connector)
        });

        emit WrapperCreated(wrapper, connector);

        return wrapper;
    }

    function i_accessManager() public view override returns (AccessManager) {
        return AccessManager(_i_accessManager);
    }
}
