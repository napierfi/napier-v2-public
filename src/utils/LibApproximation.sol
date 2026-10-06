// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";

import {ITokiHook} from "../interfaces/ITokiHook.sol";
import {TokiSwap} from "./TokiSwap.sol";

import "../Types.sol";
import "../Errors.sol";

library LibApproximation {
    using SafeCastLib for *;
    using {isEpsZero} for ApproximationParams;

    uint256 internal constant DEFAULT_BINSEARCH_EPSILON = 0.00005e18; // 0.005% relative error
    int256 internal constant IWAD = 1e18;

    /// @notice Binary search for an exact amount of PT to be sold to swap exact underlying token for YT
    /// @param approx guessMin must be positive and guessMax must be greater than guessMin
    /// @dev Reference: https://github.com/pendle-finance/pendle-core-v2-public/blob/5aaeaeda6166560e51f5de46a48ebff57e676793/contracts/router/math/MarketApproxLibV2.sol#L30
    function binsearchExactUnderlyingForYt(
        TokiSwap.PoolState memory state,
        ITokiHook.ImmutableParams memory immutables,
        TokiSwap.TokiAmmParams memory ammParams,
        ApproximationParams memory approx,
        int256 amountSpecified // Negative
    )
        internal
        view
        returns (
            int256 bestUnderlying,
            int256 bestPt,
            uint256 bestSwapFee,
            uint256 bestFeeToCuratorAndProtocol,
            uint256 previewDebt
        )
    {
        // Initialize binary search bounds
        // min/max must be positive

        if (approx.guessMin > approx.guessMax) {
            revert Errors.ApproximationParams_InvalidGuess();
        }

        if (approx.guessMin < 0) revert Errors.ApproximationParams_InvalidGuess();

        approx.guessMin = approx.isEpsZero()
            ? TokiSwap.convertToAssets(uint256(-amountSpecified), ammParams.maxscale).toInt256()
            : approx.guessMin;
        approx.guessMax = approx.isEpsZero() ? -TokiSwap.computeMaxPtIn(state, ammParams) : approx.guessMax;
        approx.eps = FixedPointMathLib.ternary(approx.isEpsZero(), DEFAULT_BINSEARCH_EPSILON, approx.eps);

        // Binary search for the exact amount of PT to be sold
        while (approx.guessMin <= approx.guessMax) {
            int256 mid = (approx.guessMin + approx.guessMax) / 2;

            // Try to swap exact PT amount
            (int256 uAmount,, uint256 sFee, uint256 fCurProt) =
                TokiSwap.computeSwapExactPrincipal(state, ammParams, -mid); // Negative mid because we're selling PT

            previewDebt = immutables.principalToken.previewIssue(uint256(mid));

            // for sure abs(previewDebt) >= abs(uAmount) since we are swapping PT to underlying
            int256 underlyingToPull = uAmount - previewDebt.toInt256(); // Negative

            if (underlyingToPull <= amountSpecified) {
                // Too much underlying needed, try smaller PT
                approx.guessMax = mid - 1;
            } else {
                // Found a valid solution
                bestPt = -mid;
                bestUnderlying = uAmount;
                bestSwapFee = sFee;
                bestFeeToCuratorAndProtocol = fCurProt;

                int256 error_mid = ((amountSpecified - underlyingToPull) * IWAD) / amountSpecified;

                // Break if relative error is small enough and positive (using less underlying than specified)
                if (error_mid < int256(approx.eps)) {
                    return (bestUnderlying, bestPt, bestSwapFee, bestFeeToCuratorAndProtocol, previewDebt);
                }

                approx.guessMin = mid + 1;
            }
        }

        revert Errors.LibApproximation_NoSolutionFound();
    }

    /// @notice Find the optimal amount of PT to be sold to add liquidity with a single token but without issuing YTs
    /// @param approx guessMin must be positive and guessMax must be greater than guessMin
    function binsearchSwapExactPrincipalToAddLiquidity(
        TokiSwap.PoolState memory state,
        TokiSwap.TokiAmmParams memory ammParams,
        ApproximationParams memory approx,
        int256 amount0 // Negative because we're selling underlying to PT
    )
        internal
        pure
        returns (int256 bestUnderlying, int256 bestPt, uint256 bestSwapFee, uint256 bestFeeToCuratorAndProtocol)
    {
        // Initialize binary search bounds
        // min/max must be positive

        if (approx.guessMin > approx.guessMax) {
            revert Errors.ApproximationParams_InvalidGuess();
        }

        if (approx.guessMin < 0) revert Errors.ApproximationParams_InvalidGuess();

        approx.guessMax = approx.isEpsZero() ? TokiSwap.computeMaxPtOut(state, ammParams) : approx.guessMax;
        approx.eps = FixedPointMathLib.ternary(approx.isEpsZero(), DEFAULT_BINSEARCH_EPSILON, approx.eps);

        // Binary search for optimal PT amount to buy
        while (approx.guessMin <= approx.guessMax) {
            int256 mid = (approx.guessMin + approx.guessMax) / 2;
            // Calculate cost of swapping underlying -> PT for this amount
            // uAmount: negative, mid: positive
            (int256 uAmount,, uint256 sFee, uint256 fCurProt) =
                TokiSwap.computeSwapExactPrincipal(state, ammParams, mid);

            // For optimal liquidity addition, the user's remaining ratio should match the pool's ratio
            // remainingUnderlying / principals = newBalance0 / newBalance1
            // Cross multiply to avoid division: remainingUnderlying * newBalance1 = principals * newBalance0

            // Need more input than the user provided. Try smaller PT output
            if (uAmount < amount0) {
                approx.guessMax = mid - 1;
                continue;
            }

            uint256 a;
            uint256 b;
            {
                Uint128x2 balances = state.balances;
                // Calculate the pool state after this swap would be executed
                uint256 newBalance0 = balances.value0() + uint256(-uAmount) - fCurProt;
                uint256 newBalance1 = balances.value1() - uint256(mid);

                a = uint256(mid) * newBalance0;
                b = uint256(-amount0 + uAmount) * newBalance1; // No underflow
            }

            if (a > b) {
                // Too much PT output, try smaller amount
                approx.guessMax = mid - 1;
            } else {
                approx.guessMin = mid + 1;
            }

            uint256 error_mid = (FixedPointMathLib.dist(a, b) * uint256(IWAD)) / b; // abs(a - b) / b

            // Break if relative error is small enough
            if (error_mid < approx.eps) {
                // Found a valid solution
                bestPt = mid;
                bestUnderlying = uAmount;
                bestSwapFee = sFee;
                bestFeeToCuratorAndProtocol = fCurProt;
                return (bestUnderlying, bestPt, bestSwapFee, bestFeeToCuratorAndProtocol);
            }
        }

        revert Errors.LibApproximation_NoSolutionFound();
    }
}
