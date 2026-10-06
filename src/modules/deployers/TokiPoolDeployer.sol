// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Interfaces
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IPoolDeployer} from "../../interfaces/IPoolDeployer.sol";
import {ITokiHook} from "../../interfaces/ITokiHook.sol";

import "../../Types.sol";
import "../../Errors.sol";

import {ReentrancyGuardTransient} from "solady/src/utils/ReentrancyGuardTransient.sol";
import {AccessManaged, AccessManager} from "../AccessManager.sol";

/// @notice Deployer for Uniswap V4 Custom Curve hook instance
contract TokiPoolDeployer is IPoolDeployer, ReentrancyGuardTransient, AccessManaged {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           EVENTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event HookSet(address indexed hook, bool enabled);
    event LiquidityTokenImplementationSet(address indexed hook, address indexed implementation, bool enabled);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           STORAGE                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Napier v2 factory
    address public immutable i_factory;

    /// @notice Whitelist of TokiPool hook
    mapping(address hook => bool enabled) s_hookEnabled;

    /// @notice Whitelist of LiquidityToken implementations
    mapping(address hook => mapping(address liquidityToken => bool enabled)) s_liquidityTokenImplementations;

    /// @notice Mapping of poolId to TokiPool hook
    mapping(PoolId poolId => address hook) s_poolIdToHook;

    constructor(address factory, address hook, address liquidityTokenImplementation) {
        i_factory = factory;
        if (hook != address(0)) {
            s_hookEnabled[hook] = true;
            emit HookSet(hook, true);
        }
        if (liquidityTokenImplementation != address(0)) {
            s_liquidityTokenImplementations[hook][liquidityTokenImplementation] = true;
            emit LiquidityTokenImplementationSet(hook, liquidityTokenImplementation, true);
        }
    }

    function deploy(address underlying, address principalToken, bytes calldata data)
        external
        payable
        nonReentrant
        returns (address)
    {
        if (msg.sender != i_factory) revert Errors.TokiPoolDeployer_OnlyFactory();

        ITokiHook.TokiPoolDeploymentParams memory params = abi.decode(data, (ITokiHook.TokiPoolDeploymentParams));

        // Check if hook is enabled
        if (!s_hookEnabled[params.hook]) {
            revert Errors.TokiPoolDeployer_InvalidHook();
        }

        // Check if implementation is enabled
        if (!s_liquidityTokenImplementations[params.hook][params.liquidityTokenImplementation]) {
            revert Errors.TokiPoolDeployer_InvalidLiquidityTokenImplementation();
        }

        // Check if hooklet is valid
        if (address(params.hooklet) != address(0) && (address(params.hooklet).code.length == 0)) {
            revert Errors.TokiPoolDeployer_InvalidHooklet();
        }

        // Currency0 must be less than Currency1 (PrincipalToken)
        if (underlying > principalToken) {
            revert Errors.TokiPoolDeployer_BadCurrencyOrder();
        }

        // Initialize a pool with PT / underlying token
        // Currency0 is underlying token, Currency1 is PT
        (PoolKey memory poolKey, address liquidityToken) =
            ITokiHook(params.hook).deploy(underlying, principalToken, params);

        s_poolIdToHook[poolKey.toId()] = params.hook;

        return liquidityToken;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                               VIEW                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function hookEnabled(address hook) public view returns (bool) {
        return s_hookEnabled[hook];
    }

    function liquidityTokenImplementationEnabled(address hook, address implementation) public view returns (bool) {
        return s_liquidityTokenImplementations[hook][implementation];
    }

    function hookOf(PoolId poolId) public view returns (address) {
        return s_poolIdToHook[poolId];
    }

    function i_accessManager() public view override returns (AccessManager) {
        return AccessManaged(i_factory).i_accessManager();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           ADMIN                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function setHook(address hook, bool enabled) external restricted {
        if (hook.code.length == 0) revert Errors.TokiPoolDeployer_InvalidHook();
        s_hookEnabled[hook] = enabled;
        emit HookSet(hook, enabled);
    }

    function setLiquidityTokenImplementation(address hook, address implementation, bool enabled) external restricted {
        if (hook.code.length == 0) revert Errors.TokiPoolDeployer_InvalidHook();
        if (implementation.code.length == 0) revert Errors.TokiPoolDeployer_InvalidLiquidityTokenImplementation();

        s_liquidityTokenImplementations[hook][implementation] = enabled;
        emit LiquidityTokenImplementationSet(hook, implementation, enabled);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           INTERNAL                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Uniswap V4 requires chains that support TSTORE/TLOAD
    /// @dev Reduce code size by using TSTORE/TLOAD every chain
    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }
}
