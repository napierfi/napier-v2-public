// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";

import "../Types.sol";
import "../Errors.sol";

/// @notice Math utilities for Uniswap V4 TokiHook
library LiquidityAmounts {
    using SafeCastLib for uint256;

    uint256 internal constant MINIMUM_LIQUIDITY = 1000; // Uniswap V2 style lock

    /// @notice Compute the liquidity for a given amount of token0 and token1
    function getLiquidityForAmounts(uint256 amount0, uint256 amount1, Uint128x2 balances, uint256 totalLiquidity)
        internal
        pure
        returns (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent)
    {
        if (totalLiquidity == 0) {
            liquidity = FixedPointMathLib.sqrt(amount0 * amount1);
            if (liquidity <= MINIMUM_LIQUIDITY) {
                revert Errors.LiquidityAmounts_InsufficientInitialLiquidity();
            }
            liquidity -= MINIMUM_LIQUIDITY;
            amount0Spent = amount0;
            amount1Spent = amount1;
        } else {
            (uint128 balance0, uint128 balance1) = balances.unpack();
            uint256 liquidity0 = (amount0 * totalLiquidity) / balance0;
            uint256 liquidity1 = (amount1 * totalLiquidity) / balance1;
            if (liquidity0 < liquidity1) {
                liquidity = liquidity0;
                amount0Spent = amount0;
                amount1Spent = FixedPointMathLib.mulDivUp(liquidity, balance1, totalLiquidity);
            } else {
                liquidity = liquidity1;
                amount1Spent = amount1;
                amount0Spent = FixedPointMathLib.mulDivUp(liquidity, balance0, totalLiquidity);
            }
        }
    }

    /// @notice Compute the amount of token0 and token1 given a liquidity amount
    function getAmountsForLiquidity(uint256 liquidity, uint256 totalLiquidity, Uint128x2 balances)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        (uint128 balance0, uint128 balance1) = balances.unpack();
        if (liquidity == 0) {
            return (0, 0);
        }
        if (totalLiquidity == 0) {
            revert Errors.LiquidityAmounts_NoLiquidity();
        }
        if (liquidity > totalLiquidity) {
            revert Errors.LiquidityAmounts_LiquidityExceedsTotalLiquidity();
        }
        amount0 = FixedPointMathLib.mulDiv(liquidity, balance0, totalLiquidity);
        amount1 = FixedPointMathLib.mulDiv(liquidity, balance1, totalLiquidity);
    }
}
