// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {LibClone} from "solady/src/utils/LibClone.sol";

import {Factory} from "../../Factory.sol";
import {AccessManaged, AccessManager} from "../../modules/AccessManager.sol";
import {IChainlinkCompatibleAggregatorV3} from "./IChainlinkCompatibleAggregatorV3.sol";

/// @notice Factory for cloning ChainlinkOracle instances
/// @dev ChainlinkOracle implementation must implement `initialize(bytes)`
contract ChainlinkOracleFactory is AccessManaged {
    Factory public immutable i_factory;

    /// @notice The implementation must implement `IChainlinkCompatibleAggregatorV3`
    mapping(address implementation => bool) public s_implementations;

    error ChainlinkOracleFactory_ImplementationNotDeployed();

    event OracleDeployed(address indexed instance, address indexed implementation);

    constructor(Factory factory) {
        i_factory = factory;
    }

    /// @notice Clone a new instance of AggregatorV3Interface-style oracle.
    /// @param implementation Address of the oracle implementation
    /// @param args ERC1967I immutable arguments
    /// @param initializationData Initialization data on `initialize(bytes)` call
    function clone(address implementation, bytes calldata args, bytes calldata initializationData)
        external
        returns (address instance)
    {
        if (!s_implementations[implementation]) {
            revert ChainlinkOracleFactory_ImplementationNotDeployed();
        }

        instance = LibClone.clone(implementation, args);

        IChainlinkCompatibleAggregatorV3(instance).initialize(initializationData);

        emit OracleDeployed(instance, implementation);
    }

    function setImplementation(address implementation, bool approve) external restricted {
        s_implementations[implementation] = approve;
    }

    function i_accessManager() public view override returns (AccessManager) {
        return i_factory.i_accessManager();
    }
}
