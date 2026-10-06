// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

import {DataTypes} from "../interfaces/DataTypes.sol";
import {IPool} from "../interfaces/IPool.sol";
import {IAToken} from "../interfaces/IAToken.sol";
import {IScaledBalanceToken} from "../interfaces/IScaledBalanceToken.sol";
import "./AaveV3Constants.sol";

library AaveV3PoolLens {
    // forgefmt: disable-start
    /// @dev Get the maximum amount of assets that can be supplied to the pool.
    /// Mirrors Aave's reserve update and supply-cap validation without mutating reserve state.
    /// Reference: https://github.com/aave-dao/aave-v3-origin/blob/5431379f8beb4d7128c84a81ced3917d856efa84/src/contracts/protocol/libraries/logic/ValidationLogic.sol#L64-L85
    function maxSuppliable(IAToken aToken) internal view returns (uint256) {
        // returns 0 if reserve is not active, frozen, or paused
        // returns max uint256 value if supply cap is 0 (not capped)
        // returns supply cap - current amount supplied as max suppliable if there is a supply cap for this reserve

        address asset = aToken.UNDERLYING_ASSET_ADDRESS();
        IPool pool = aToken.POOL();
        DataTypes.ReserveData memory reserveData = pool.getReserveData(asset);

        uint256 reserveConfigMap = reserveData.configuration.data;
        uint256 supplyCap = (reserveConfigMap & ~AAVE_SUPPLY_CAP_MASK) >> AAVE_SUPPLY_CAP_BIT_POSITION;

        if (
            (reserveConfigMap & ~AAVE_ACTIVE_MASK == 0) ||
            (reserveConfigMap & ~AAVE_FROZEN_MASK != 0) ||
            (reserveConfigMap & ~AAVE_PAUSED_MASK != 0)
        ) {
            return 0;
        } else if (supplyCap == 0) {
            return type(uint256).max;
        } else {
            uint256 liquidityIndex = pool.getReserveNormalizedIncome(asset);
            uint256 reserveFactor =
                uint16(reserveConfigMap >> AAVE_RESERVE_FACTOR_BIT_POSITION);
            uint256 accruedToTreasury = uint256(reserveData.accruedToTreasury)
                + _pendingScaledTreasury(pool, asset, reserveData, liquidityIndex, reserveFactor);
            uint256 currentSupply = FixedPointMathLib.fullMulDivUp(
                aToken.scaledTotalSupply() + accruedToTreasury, liquidityIndex, AAVE_RAY
            );
            uint256 supplyCapWithDecimals = supplyCap * 10 ** ERC20(asset).decimals();
            return supplyCapWithDecimals > currentSupply ? supplyCapWithDecimals - currentSupply : 0;
        }
    }
    // forgefmt: disable-end

    function _pendingScaledTreasury(
        IPool pool,
        address asset,
        DataTypes.ReserveData memory reserveData,
        uint256 liquidityIndex,
        uint256 reserveFactor
    ) private view returns (uint256) {
        // Aave accrues the reserve factor before checking a supply against the cap. Rounding every
        // positive component up makes this view an upper bound on supply and a lower bound on capacity.
        // Reference: https://github.com/aave-dao/aave-v3-origin/blob/5431379f8beb4d7128c84a81ced3917d856efa84/src/contracts/protocol/libraries/logic/ReserveLogic.sol#L217-L243
        if (reserveFactor == 0 || reserveData.lastUpdateTimestamp == uint40(block.timestamp)) return 0;

        uint256 scaledVariableDebt = IScaledBalanceToken(reserveData.variableDebtTokenAddress).scaledTotalSupply();
        if (scaledVariableDebt == 0) return 0;

        uint256 currentVariableDebt =
            FixedPointMathLib.fullMulDivUp(scaledVariableDebt, pool.getReserveNormalizedVariableDebt(asset), AAVE_RAY);
        uint256 previousVariableDebt =
            FixedPointMathLib.fullMulDiv(scaledVariableDebt, reserveData.variableBorrowIndex, AAVE_RAY);
        uint256 treasuryAssets = FixedPointMathLib.fullMulDivUp(
            currentVariableDebt - previousVariableDebt, reserveFactor, AAVE_PERCENTAGE_FACTOR
        );
        return FixedPointMathLib.fullMulDivUp(treasuryAssets, AAVE_RAY, liquidityIndex);
    }

    /// @notice Get the maximum amount of assets that can be withdrawn from the pool
    /// @dev Returns 0 if the reserve is inactive or paused. For reserves using virtual accounting,
    /// returns the smaller of the accounted liquidity and the underlying held by the aToken.
    /// @return maxWithdraw The maximum amount of assets that can be withdrawn
    function maxWithdrawFromPool(IAToken aToken) internal view returns (uint256) {
        address asset = aToken.UNDERLYING_ASSET_ADDRESS();
        IPool pool = aToken.POOL();
        uint256 reserveConfigMap = pool.getReserveData(asset).configuration.data;

        if (_isNotActiveOrPaused(reserveConfigMap)) return 0;

        uint256 underlyingBalance = ERC20(asset).balanceOf(address(aToken));
        if ((reserveConfigMap & AAVE_VIRTUAL_ACC_ACTIVE_MASK) == 0) return underlyingBalance;

        return FixedPointMathLib.min(underlyingBalance, pool.getVirtualUnderlyingBalance(asset));
    }

    /// @notice Returns true if market is not active or paused, false otherwise
    function isNotActiveOrPaused(IAToken aToken) internal view returns (bool) {
        address asset = aToken.UNDERLYING_ASSET_ADDRESS();
        uint256 reserveConfigMap = aToken.POOL().getReserveData(asset).configuration.data;
        return _isNotActiveOrPaused(reserveConfigMap);
    }

    function _isNotActiveOrPaused(uint256 reserveConfigMap) private pure returns (bool) {
        return (reserveConfigMap & ~AAVE_ACTIVE_MASK == 0) || (reserveConfigMap & ~AAVE_PAUSED_MASK != 0);
    }
}
