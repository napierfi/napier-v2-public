// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {LibClone} from "solady/src/utils/LibClone.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ITokiHook, StateLibrary} from "../interfaces/ITokiHook.sol";
import {TokiPoolToken} from "../tokens/TokiPoolToken.sol";

import {AccessManager, AccessManaged} from "../modules/AccessManager.sol";
import {LibOracle} from "../utils/LibOracle.sol";
import {TWAPPrice} from "./TWAPPrice.sol";

/// @dev ERC1967I Immutable args: abi.encode(factory)
/// @dev Stored price: The oracle functions return the oracle based on the last stored lnImpliedRate when `duration == 0`.
///      This is not the spot price and can be stale.
/// @dev Oracle caveats:
///      Rehypothecation yield or vault share-price shocks can cause the oracle to diverge from
///      the spot price
contract TokiOracle is AccessManaged, Initializable, UUPSUpgradeable {
    error TokiOracle_InvalidBlockInterval();

    /// @notice Storage slot for the oracle: `cast index-erc7201 napier-v2.v4oracle.storage`
    bytes32 constant ORACLE_STORAGE_SLOT = 0x59ddc0672fc4d55f72b7d74823ca8dbdbad7ca43f93675ba71dd128bb05ae900;
    uint16 constant DEFAULT_L1_BLOCK_INTERVAL_MS = 11000;
    uint16 constant DEFAULT_L2_BLOCK_INTERVAL_MS = 1000;

    /// @param blockIntervalMs
    /// @notice The params is used to make sure TWAP oracle availability
    /// @dev blockIntervalMs should be configured so that blockIntervalMs / 1000 < actual block cycle
    /// @dev blockIntervalMs should be greater or equal to 1000 since the oracle only records one
    /// rate per timestamp
    /// For example, on Ethereum blockIntervalMs = 11000, where 11000/1000 = 11 < 12
    ///                 Arbitrum blockIntervalMs = 1000, since we can't do better than this
    struct TokiOracleNamespace {
        uint16 blockIntervalMs;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(uint16 _blockIntervalMs) external initializer {
        if (_blockIntervalMs == 0) {
            _blockIntervalMs = block.chainid == 1 ? DEFAULT_L1_BLOCK_INTERVAL_MS : DEFAULT_L2_BLOCK_INTERVAL_MS;
        }

        _setBlockIntervalMs(_blockIntervalMs);
    }

    function i_accessManager() public view override returns (AccessManager) {
        return AccessManager(AccessManaged(i_factory()).i_accessManager());
    }

    function i_factory() public view returns (address) {
        return abi.decode(LibClone.argsOnERC1967I(address(this)), (address));
    }

    function blockIntervalMs() external view returns (uint16) {
        return _getStorage().blockIntervalMs;
    }

    function _authorizeUpgrade(address newImplementation) internal override restricted {}

    function _getStorage() internal pure returns (TokiOracleNamespace storage s) {
        assembly {
            s.slot := ORACLE_STORAGE_SLOT
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*              ORACLE TO UNDERLYING TOKEN                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function convertPtToUnderlying(address liquidityToken, uint32 duration, uint256 principals)
        external
        view
        returns (uint256)
    {
        return TWAPPrice.convertPtToUnderlying(liquidityToken, duration, principals);
    }

    function convertYtToUnderlying(address liquidityToken, uint32 duration, uint256 principals)
        external
        view
        returns (uint256)
    {
        return TWAPPrice.convertYtToUnderlying(liquidityToken, duration, principals);
    }

    function convertLpToUnderlying(address liquidityToken, uint32 duration, uint256 liquidity)
        external
        view
        returns (uint256)
    {
        return TWAPPrice.convertLpToUnderlying(liquidityToken, duration, liquidity);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   ORACLE TO BASE TOKEN                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice make sure you have taken into account the risk of not being able to withdraw from SY to Asset
    function convertPtToAssets(address liquidityToken, uint32 duration, uint256 principals)
        external
        view
        returns (uint256)
    {
        return TWAPPrice.convertPtToAssets(liquidityToken, duration, principals);
    }

    function convertYtToAssets(address liquidityToken, uint32 duration, uint256 principals)
        external
        view
        returns (uint256)
    {
        return TWAPPrice.convertYtToAssets(liquidityToken, duration, principals);
    }

    function convertLpToAssets(address liquidityToken, uint32 duration, uint256 liquidity)
        external
        view
        returns (uint256)
    {
        return TWAPPrice.convertLpToAssets(liquidityToken, duration, liquidity);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           UTILITY                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice A check function for the cardinality status of the liquidityToken
    /// @dev This function doesn't check if the liquidityToken is valid
    /// @param liquidityToken address of the liquidity token
    /// @param twapWindow twap window duration in seconds
    /// @return needsCapacityIncrease a boolean indicates whether the cardinality should be increased to serve the twap window
    /// @return cardinalityRequired the amount of cardinality required for the twap window
    /// @return hasOldestData a boolean indicates whether at least one historical data before twapWindow ago is available
    function checkTwapReadiness(address liquidityToken, uint32 twapWindow)
        external
        view
        returns (bool needsCapacityIncrease, uint16 cardinalityRequired, bool hasOldestData)
    {
        ITokiHook hook = ITokiHook(TokiPoolToken(liquidityToken).i_hook());
        PoolId id = TokiPoolToken(liquidityToken).i_poolKey().toId();

        // Get observation state using StateLibrary pattern
        (uint16 cardinality, uint16 cardinalityNext, uint16 observationIndex) =
            StateLibrary.getObservationState(hook, id);

        // Check if capacity increase is needed
        cardinalityRequired = LibOracle.getCardinalityRequired(twapWindow, _getStorage().blockIntervalMs);
        needsCapacityIncrease = cardinalityNext < cardinalityRequired;

        // Check if the oldest data is available
        (uint32 oldestTimestamp,, bool initialized) = observations(hook, id, (observationIndex + 1) % cardinality);
        if (!initialized) {
            (oldestTimestamp,,) = observations(hook, id, 0);
        }
        hasOldestData = oldestTimestamp < (block.timestamp - twapWindow);
    }

    function observations(ITokiHook hook, PoolId id, uint256 index)
        public
        view
        returns (uint32 blockTimestamp, uint216 lnImpliedRateCumulative, bool initialized)
    {
        return StateLibrary.observations(hook, id, index);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        ADMIN FUNCTIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function setBlockIntervalMs(uint16 newBlockIntervalMs) external restricted {
        _setBlockIntervalMs(newBlockIntervalMs);
    }

    function _setBlockIntervalMs(uint16 newBlockIntervalMs) internal {
        if (newBlockIntervalMs < LibOracle.MILLISECONDS_PER_SECOND) {
            revert TokiOracle_InvalidBlockInterval();
        }

        TokiOracleNamespace storage s = _getStorage();
        s.blockIntervalMs = newBlockIntervalMs;
    }
}
