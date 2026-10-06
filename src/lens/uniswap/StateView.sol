// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {SSTORE2} from "solady/src/utils/SSTORE2.sol";
import {PoolKey, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import "../../Types.sol";
import "../../Errors.sol";
import {CustomRevert} from "../../utils/CustomRevert.sol";
import {ITokiHook, StateLibrary, ImmutableParamsLib} from "../../interfaces/ITokiHook.sol";
import {TokiPoolToken} from "../../tokens/TokiPoolToken.sol";
import {TokiPoolDeployer} from "../../modules/deployers/TokiPoolDeployer.sol";

/// @notice Public interface for accessing TokiHook pool state via StateLibrary
/// @dev Exposes StateLibrary's internal functions as public view functions for external consumption
contract StateView {
    using CustomRevert for bytes4;

    TokiPoolDeployer public immutable i_tokiPoolDeployer;

    constructor(TokiPoolDeployer tokiPoolDeployer) {
        i_tokiPoolDeployer = tokiPoolDeployer;
    }

    function hookOf(PoolId id) public view returns (ITokiHook hook) {
        hook = ITokiHook(i_tokiPoolDeployer.hookOf(id));
        _validateHook(hook);
    }

    function poolKeyOf(PoolId id) external view returns (PoolKey memory poolKey) {
        ITokiHook hook = hookOf(id);
        address liquidityToken = ImmutableParamsLib.getLiquidityToken(hook, id);
        poolKey = TokiPoolToken(liquidityToken).i_poolKey();
    }

    function _validateHook(ITokiHook hook) internal pure {
        if (address(hook) == address(0)) Errors.BadTokiPool.selector.revertWith();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       POOL STATE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function getTotalBalances(PoolId id) external view returns (uint128 totalBalance0, uint128 totalBalance1) {
        ITokiHook hook = hookOf(id);
        (totalBalance0, totalBalance1) = hook.getTotalBalances(id).unpack();
    }

    /// @notice Returns the reserves of the pool (vault shares for currency0 and currency1)
    function getReserves(PoolId id) external view returns (uint128 reserve0, uint128 reserve1) {
        ITokiHook hook = hookOf(id);
        uint256 reserves = StateLibrary.getReserves(hook, id);
        (reserve0, reserve1) = Uint128x2.wrap(reserves).unpack();
    }

    /// @notice Returns the accumulated fees for curator and protocol
    function getFees(PoolId id) external view returns (uint128 curatorFees, uint128 protocolFees) {
        ITokiHook hook = hookOf(id);
        uint256 fees = StateLibrary.getFees(hook, id);
        (curatorFees, protocolFees) = Uint128x2.wrap(fees).unpack();
    }

    /// @notice Returns the raw token balances held directly in PoolManager
    function getRawBalances(PoolId id) external view returns (uint128 rawBalance0, uint128 rawBalance1) {
        ITokiHook hook = hookOf(id);
        uint256 rawBalances = StateLibrary.getRawBalances(hook, id);
        (rawBalance0, rawBalance1) = Uint128x2.wrap(rawBalances).unpack();
    }

    /// @notice Returns the current logarithmic implied rate
    function getLnImpliedRate(PoolId id) external view returns (uint96 lnImpliedRate) {
        ITokiHook hook = hookOf(id);
        return StateLibrary.getLnImpliedRate(hook, id);
    }

    /// @notice Returns the pointer to immutable parameters stored via SSTORE2
    /// @return pointer Address pointing to SSTORE2 storage containing immutable pool parameters
    function getPointer(PoolId id) external view returns (address pointer) {
        ITokiHook hook = hookOf(id);
        return StateLibrary.getPointer(hook, id);
    }

    /// @notice Returns the total liquidity in the pool
    /// @return liquidity Total liquidity as uint128
    function getLiquidity(PoolId id) external view returns (uint128 liquidity) {
        ITokiHook hook = hookOf(id);
        return StateLibrary.getLiquidity(hook, id);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         IMMUTABLES                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function getImmutableData(PoolId id) external view returns (bytes memory) {
        ITokiHook hook = hookOf(id);
        return SSTORE2.read(StateLibrary.getPointer(hook, id));
    }

    function getLiquidityToken(PoolId id) external view returns (address liquidityToken) {
        ITokiHook hook = hookOf(id);
        return ImmutableParamsLib.getLiquidityToken(hook, id);
    }

    function getVaults(PoolId id) external view returns (address vault0, address vault1) {
        ITokiHook hook = hookOf(id);
        (vault0, vault1) = ImmutableParamsLib.getVaults(hook, id);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         ORACLE                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Returns the oracle observation state
    /// @return cardinality The number of populated observations
    /// @return cardinalityNext The target number of observations
    /// @return observationIndex The index of the most recent observation
    function getObservationState(PoolId id)
        external
        view
        returns (uint16 cardinality, uint16 cardinalityNext, uint16 observationIndex)
    {
        ITokiHook hook = hookOf(id);
        return StateLibrary.getObservationState(hook, id);
    }

    /// @notice Returns a specific oracle observation
    /// @return blockTimestamp The timestamp when the observation was recorded
    /// @return lnImpliedRateCumulative The cumulative ln(implied rate) at that time
    /// @return initialized Whether the observation slot has been initialized
    function observations(PoolId id, uint256 index)
        external
        view
        returns (uint32 blockTimestamp, uint216 lnImpliedRateCumulative, bool initialized)
    {
        ITokiHook hook = hookOf(id);
        return StateLibrary.observations(hook, id, index);
    }
}
