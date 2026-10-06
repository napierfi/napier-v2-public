// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {LibClone} from "solady/src/utils/LibClone.sol";

import {VaultConnectorRegistry} from "../modules/connectors/VaultConnectorRegistry.sol";
import {IWrapper} from "./IWrapper.sol";
import {WrapperConnector} from "../modules/connectors/WrapperConnector.sol";

import "../Errors.sol";
import {AccessManager, AccessManaged} from "../modules/AccessManager.sol";

/// @title WrapperFactory
/// @notice Factory for creating Napier wrappers and connectors
/// @dev Access to `VaultConnectorRegistry.setConnector()` must be granted to this contract by the `AccessManager`
contract WrapperFactory is AccessManaged {
    address private immutable _i_accessManager;
    address public immutable i_weth;

    /// @notice The registry of vault connectors
    VaultConnectorRegistry public s_vaultConnectorRegistry;

    /// @notice The implementation of connector for wrapper
    address public s_connectorImplementation;

    /// @notice The implementation of wrapper
    mapping(address implementation => bool valid) public s_wrapperImplementations;

    /// @notice Wrapper instance => implementation
    mapping(address wrapper => address implementation) public s_wrappers;

    event SetWrapperImplementation(address indexed implementation, bool valid);
    event SetConnectorImplementation(address indexed implementation);
    event SetVaultConnectorRegistry(address indexed oldRegistry, address indexed newRegistry);
    event WrapperCreated(address indexed wrapper, address indexed connector);

    constructor(address accessManager, address weth, address vaultConnectorRegistry, address connectorImplementation) {
        _i_accessManager = accessManager;
        i_weth = weth;
        s_vaultConnectorRegistry = VaultConnectorRegistry(vaultConnectorRegistry);
        s_connectorImplementation = connectorImplementation;
    }

    function setWrapperImplementation(address implementation, bool valid) external restricted {
        s_wrapperImplementations[implementation] = valid;
        emit SetWrapperImplementation(implementation, valid);
    }

    function setConnectorImplementation(address implementation) external restricted {
        s_connectorImplementation = implementation;
        emit SetConnectorImplementation(implementation);
    }

    function setVaultConnectorRegistry(address _vaultConnectorRegistry) external restricted {
        address oldRegistry = address(s_vaultConnectorRegistry);
        s_vaultConnectorRegistry = VaultConnectorRegistry(_vaultConnectorRegistry);
        emit SetVaultConnectorRegistry(oldRegistry, _vaultConnectorRegistry);
    }

    /// @notice Create a new ERC4626 Wrapper and connector
    /// @param wrapperImplementation The implementation to use for the wrapper
    /// @param args The immutable args for the wrapper
    /// @param salt The CREATE2 salt for the wrapper and connector deployment
    /// Note: Vulnerable to front-running salt. Integrators should hash sender into salt to prevent griefing via frontrunning.
    /// @return The address of the new wrapper
    function createWrapper(address wrapperImplementation, bytes calldata args, bytes32 salt)
        external
        returns (address)
    {
        if (!s_wrapperImplementations[wrapperImplementation]) {
            revert Errors.WrapperFactory_InvalidWrapperImplementation();
        }

        address wrapper = LibClone.cloneDeterministic({implementation: wrapperImplementation, args: args, salt: salt});
        IWrapper(wrapper).initialize();

        address connector = LibClone.cloneDeterministic({
            implementation: s_connectorImplementation,
            args: abi.encode(wrapper, i_weth),
            salt: salt
        });

        s_wrappers[wrapper] = wrapperImplementation;

        s_vaultConnectorRegistry.setConnector({
            target: wrapper,
            asset: IWrapper(wrapper).asset(),
            connector: WrapperConnector(payable(connector))
        });

        emit WrapperCreated(wrapper, connector);

        return wrapper;
    }

    function i_accessManager() public view override returns (AccessManager) {
        return AccessManager(_i_accessManager);
    }
}
