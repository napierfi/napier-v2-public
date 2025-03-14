// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {SSTORE2} from "solady/src/utils/SSTORE2.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {LibTransient} from "solady/src/utils/LibTransient.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";
import {EfficientHashLib} from "solady/src/utils/EfficientHashLib.sol";
// Interfaces
import "./Types.sol";
import {IPoolDeployer} from "./interfaces/IPoolDeployer.sol";
// Modules
import {BaseModule} from "./modules/BaseModule.sol";
import {PrincipalToken} from "./tokens/PrincipalToken.sol";
import {AccessManager, AccessManaged} from "./modules/AccessManager.sol";
import {VaultInfoResolver} from "./modules/resolvers/VaultInfoResolver.sol";
// Libraries
import {LibBlueprint} from "./utils/LibBlueprint.sol";
import {ModuleAccessor} from "./utils/ModuleAccessor.sol";
import {Errors} from "./Errors.sol";
import {Events} from "./Events.sol";
import "src/Constants.sol" as Constants;

/// @notice Deployment Suite
///  - Factory is responsible for deploying PrincipalToken, YT and Pool instances.
///  - Factory is agnostic to type of AMM by supporting multiple pool deployers implementations.
///  - Factory supports multiple principalToken implementations.
contract Factory is AccessManaged, UUPSUpgradeable {
    /// @notice EIP1967 proxy immutable arguments offset
    uint256 constant ARGS_ON_ERC1967_FACTORY_ARG_OFFSET = 0x00;

    /// @notice Default split ratio for the fee module (100% to curator)
    uint256 public constant DEFAULT_SPLIT_RATIO_BPS = Constants.DEFAULT_SPLIT_RATIO_BPS;

    /// @notice Pool deployers (factories)
    /// @dev Support multiple pool deployers for different AMM implementations.
    mapping(address deployer => bool enable) public s_poolDeployers;

    /// @notice Registered PrincipalToken implementations: PrincipalToken EIP5020 Blueprint -> YieldToken EIP5020 Blueprint
    /// @dev `ytBlueprint` == 0x0 means the PrincipalToken is disabled.
    /// @dev Key design decisions:
    /// 1. EIP-5202: Efficient bytecode cloning for multiple instances.
    /// 2. Minimal proxy: Avoids delegatecall overhead. PrincipalToken is frequently called.
    /// 3. Factory: Separate factory for PrincipalToken causes code duplication.
    mapping(address blueprint => address ytBlueprint) public s_ytBlueprints;

    /// @notice Registered resolver blueprints
    /// @notice resolver blueprint -> enable
    mapping(address blueprint => bool enable) public s_resolverBlueprints;

    /// @notice AccessManager Minimal proxy implementation
    mapping(address implementation => bool enable) public s_accessManagerImplementations;

    /// @notice Lookup for pool and principalToken instances
    /// @dev This is the only way to know whether a pool is canonical or not.
    mapping(address pool => address deployer) public s_pools;

    mapping(address principalToken => address blueprint) public s_principalTokens;

    /// @notice Minimal proxy implementation for modules
    mapping(ModuleIndex moduleType => mapping(address implementation => bool enabled)) public s_modules;

    /// @dev Preview function for FE integration.
    address[] s_poolList;

    /// @notice Receiver of Napier finance protocol fee
    address public s_treasury;

    /// @notice Constructor arguments for PrincipalToken instance
    struct ConstructorArg {
        address resolver;
        uint256 expiry;
        address yt;
        address accessManager;
        address modules; // SSSTORE2 pointer that stores module instances addresses
    }

    LibTransient.TBytes internal _tempArgs;

    struct Suite {
        address accessManagerImpl;
        address ptBlueprint;
        address resolverBlueprint;
        address poolDeployerImpl;
        bytes poolArgs;
        bytes resolverArgs;
    }

    struct ModuleParam {
        ModuleIndex moduleType;
        address implementation; // EIP-1167 CWIA proxy implementation
        bytes immutableData; // Immutable data for module instance. Watch out arbitrary data from user side.
    }

    /// @notice Deploy new PrincipalToken, YT, pool and modules.
    /// @notice Revert if the implementation is zero address.
    /// @notice Revert if the expiry is less than the current timestamp.
    /// @notice Revert if the suite is invalid.
    /// @param suite Suite of the PrincipalToken instance.
    /// @param params Module parameters.
    /// @param expiry Expiry timestamp of the PrincipalToken.
    /// @param curator Address of the curator. If the address is zero, no one can control the PrincipalToken instance.
    function deploy(Suite calldata suite, ModuleParam[] calldata params, uint256 expiry, address curator)
        external
        returns (address pt, address yt, address pool)
    {
        if (
            suite.ptBlueprint == address(0) || !s_resolverBlueprints[suite.resolverBlueprint]
                || !s_poolDeployers[suite.poolDeployerImpl] || !s_accessManagerImplementations[suite.accessManagerImpl]
        ) {
            revert Errors.Factory_InvalidSuite();
        }
        if (expiry <= block.timestamp) revert Errors.Factory_InvalidExpiry();

        // Deploy resolver and access manager
        address resolver = LibBlueprint.create(suite.resolverBlueprint, suite.resolverArgs);
        address accessManager = LibClone.clone(suite.accessManagerImpl);
        AccessManager(accessManager).initializeOwner(curator);

        bytes32 salt =
            EfficientHashLib.hash(block.chainid, expiry, uint256(uint160(resolver)), uint256(uint160(msg.sender)));
        pt = LibBlueprint.computeCreate2Address(salt, suite.ptBlueprint, "");

        // Stack too deep workaround
        {
            // Deploy modules, YT and PT
            address pointer = _deployModules(pt, params, true);

            yt = LibBlueprint.create(s_ytBlueprints[suite.ptBlueprint], abi.encode(pt));
            LibTransient.setCompat(_tempArgs, abi.encode(ConstructorArg(resolver, expiry, yt, accessManager, pointer)));
            LibBlueprint.create2(suite.ptBlueprint, salt);
        }

        address target = VaultInfoResolver(resolver).target();
        pool = IPoolDeployer(suite.poolDeployerImpl).deploy(target, pt, suite.poolArgs);

        emit Events.Deployed(pt, yt, pool, expiry, target);

        s_poolList.push(pool);
        s_pools[pool] = suite.poolDeployerImpl;
        s_principalTokens[pt] = suite.ptBlueprint;

        LibTransient.clearCompat(_tempArgs);
    }

    /// @notice Update existing modules for the PrincipalToken instance.
    /// @dev Revert if the caller is not authorized by the `AccessManager` of the `PrincipalToken` instance.
    /// @dev Revert if the fee module is trying to update.
    /// @dev Revert if the module type is out of bounds.
    /// @dev Revert if the module implementation is not registered.
    function updateModules(address pt, ModuleParam[] calldata params)
        external
        exists(pt)
        restrictedBy(PrincipalToken(pt).i_accessManager())
    {
        // Check if any of the params is trying to update the fee module
        for (uint256 i = 0; i != params.length;) {
            if (params[i].moduleType == FEE_MODULE_INDEX) revert Errors.Factory_CannotUpdateFeeModule();
            unchecked {
                ++i;
            }
        }

        address pointer = _deployModules(pt, params, false);
        PrincipalToken(pt).setModules(pointer);
    }

    function _deployModules(address pt, ModuleParam[] calldata params, bool initialize)
        internal
        returns (address pointer)
    {
        // If the principalToken is not set, it means the PrincipalToken instance is being deployed and the modules are not set yet.
        address[] memory modules =
            initialize ? new address[](MAX_MODULES) : ModuleAccessor.read(PrincipalToken(pt).s_modules());

        for (uint256 i = 0; i != params.length;) {
            ModuleParam calldata param = params[i];
            // CHECK
            ModuleIndex t = param.moduleType;
            if (!isValidImplementation(t, param.implementation)) revert Errors.Factory_InvalidModule();

            address instance = LibClone.clone(param.implementation, abi.encode(pt, param.immutableData));
            BaseModule(instance).initialize();

            // Replace the module address with the new one
            ModuleAccessor.set(modules, t, instance); // Revert if index is out of bounds

            emit Events.ModuleUpdated(t, instance, pt);

            unchecked {
                ++i;
            }
        }
        // CHECK: FeeModule is mandatory
        if (ModuleAccessor.get(modules, FEE_MODULE_INDEX) == address(0)) {
            revert Errors.Factory_FeeModuleRequired();
        }

        // Store the module instances
        pointer = SSTORE2.write(abi.encode(modules));
    }

    /// @notice Set PrincipalToken implementation
    /// @dev Revert if the caller is not Dev role.
    /// @param ytBlueprint EIP-5202 YT Blueprint (Zero address means set the `ptBlueprint` disabled)
    function setPrincipalTokenBlueprint(address ptBlueprint, address ytBlueprint)
        external
        restricted
        notZeroAddress(ptBlueprint)
    {
        s_ytBlueprints[ptBlueprint] = ytBlueprint;
        emit Events.PrincipalTokenImplementationSet(ptBlueprint, ytBlueprint);
    }

    /// @dev Revert if the caller is not Dev role.
    function setPoolDeployer(address deployer, bool enable) external restricted notZeroAddress(deployer) {
        s_poolDeployers[deployer] = enable;
        emit Events.PoolDeployerSet(deployer, enable);
    }

    /// @dev Revert if the caller is not Dev role.
    function setAccessManagerImplementation(address implementation, bool enable)
        external
        restricted
        notZeroAddress(implementation)
    {
        s_accessManagerImplementations[implementation] = enable;
        emit Events.AccessManagerImplementationSet(implementation, enable);
    }

    /// @dev Revert if the caller is not Dev role.
    function setResolverBlueprint(address blueprint, bool enable) external restricted notZeroAddress(blueprint) {
        s_resolverBlueprints[blueprint] = enable;
        emit Events.ResolverBlueprintSet(blueprint, enable);
    }

    /// @dev Revert if the caller is not Dev role.
    function setModuleImplementation(ModuleIndex moduleType, address implementation, bool enable)
        external
        restricted
        notZeroAddress(implementation)
    {
        if (!moduleType.isSupportedByFactory()) revert Errors.Factory_InvalidModuleType();

        s_modules[moduleType][implementation] = enable;
        emit Events.ModuleImplementationSet(moduleType, implementation, enable);
    }

    /// @dev Revert if treasury is zero address or the caller is not Admin
    function setTreasury(address treasury) external restricted notZeroAddress(treasury) {
        s_treasury = treasury;
        emit Events.TreasurySet(treasury);
    }

    function isValidImplementation(ModuleIndex moduleType, address implementation) public view returns (bool) {
        return moduleType.isSupportedByFactory() && s_modules[moduleType][implementation];
    }

    /// @notice Returns the module address for a given principal token and module type
    /// @param principalToken The address of the principal token
    /// @param moduleType The type of module to look up
    /// @dev Reverts if the principal token does not exist or if the module is not found
    function moduleFor(address principalToken, ModuleIndex moduleType)
        public
        view
        exists(principalToken)
        returns (address module)
    {
        module = ModuleAccessor.get(ModuleAccessor.read(PrincipalToken(principalToken).s_modules()), moduleType);
        if (module == address(0)) revert Errors.Factory_ModuleNotFound();
    }

    /// @notice Return pool list for FE integration.
    function getPoolList() external view returns (address[] memory) {
        return s_poolList;
    }

    /// @notice Return constructor args.
    /// @dev For easier verification, PrincipalToken instance callbacks and gets constructor arg.
    function args() external view returns (ConstructorArg memory) {
        return abi.decode(LibTransient.getCompat(_tempArgs), (ConstructorArg));
    }

    function i_accessManager() public view override returns (AccessManager) {
        bytes memory arg = LibClone.argsOnERC1967(
            address(this), ARGS_ON_ERC1967_FACTORY_ARG_OFFSET, ARGS_ON_ERC1967_FACTORY_ARG_OFFSET + 0x20
        );
        return AccessManager(abi.decode(arg, (address)));
    }

    modifier exists(address principalToken) {
        if (s_principalTokens[principalToken] == address(0)) {
            revert Errors.Factory_PrincipalTokenNotFound();
        }
        _;
    }

    modifier notZeroAddress(address implementation) {
        if (implementation == address(0)) {
            revert Errors.Factory_InvalidAddress();
        }
        _;
    }

    function _authorizeUpgrade(address newImplementation) internal override restricted {}
}
