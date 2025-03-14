// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {ERC20} from "solady/src/tokens/ERC20.sol";

import "../types/TwoCrypto.sol";
import {LibTwoCryptoNG} from "../utils/LibTwoCryptoNG.sol";

/// @notice Helper functions for TwoCrypto. This library is not meant to ever actually be called from on-chain, used from off-chain because of intensive gas cost.
library TwoCryptoNGPreviewLib {
    using LibTwoCryptoNG for TwoCrypto;

    error TwoCryptoNGPreviewLib_SolutionNotFound();

    /// @notice Maximal number of iterations in the binary search algorithm
    uint256 private constant MAX_ITERATIONS_BINSEARCH = 255;

    /**
     * @param twoCrypto : PT/YBT curve pool
     * @param i token index of token to provide
     * @param j token index of token to receive
     * @param targetDy amount out desired token `j`
     * @return dx The amount of token to provide in order to obtain targetDy after swap
     */
    function binsearch_dx(TwoCrypto twoCrypto, uint256 i, uint256 j, uint256 targetDy)
        internal
        view
        returns (uint256)
    {
        if (targetDy == 0) return 0;

        // Initial guesses: with PT/underlying token is 1
        uint256 initialDxGuess =
            convertTokenAmount(targetDy, ERC20(twoCrypto.coins(j)).decimals(), ERC20(twoCrypto.coins(i)).decimals());
        uint256 initialDy = twoCrypto.get_dy(i, j, initialDxGuess);
        return binsearch_dx_with_initial_guess(
            BinSearchInput({
                twoCrypto: twoCrypto,
                i: i,
                j: j,
                targetDy: targetDy,
                initialDxGuess: initialDxGuess,
                initialDy: initialDy
            })
        );
    }

    /// @dev Workaround for stack too deep error
    struct BinSearchInput {
        TwoCrypto twoCrypto;
        uint256 i;
        uint256 j;
        uint256 targetDy;
        uint256 initialDxGuess;
        uint256 initialDy;
    }

    function binsearch_dx_with_initial_guess(BinSearchInput memory input) private view returns (uint256) {
        // bounds should be in dx as we want our solution, the bisection of this interval, to be in dx
        uint256 lowerDx = type(uint256).max; // lower bound
        uint256 upperDx = type(uint256).max; // upper bound
        uint256 factor100;

        uint256 midDx = input.initialDxGuess;
        if (input.initialDy > input.targetDy) {
            // we overshot (target < initialDy), can set an upper bound
            upperDx = midDx;
            factor100 = 10;
        } else {
            // we undershot (initialDy <= targetDy), can set a lower bound
            lowerDx = midDx;
            factor100 = 1000;
        }

        uint256 iterations;
        while (true) {
            iterations++;

            // as long as the other bound is uninitialized, find bounds first by scaling in the direction of the uninitialzied bound.
            if (lowerDx == type(uint256).max || upperDx == type(uint256).max) {
                midDx = (midDx * factor100) / 100;
            } else {
                midDx = (lowerDx + upperDx) >> 1;
            }

            uint256 midDy = input.twoCrypto.get_dy(input.i, input.j, midDx);

            // Narrow down the interval based on the comparison
            if (midDy < input.targetDy) {
                lowerDx = midDx;
            } else {
                upperDx = midDx;
            }

            // If the midDx is a solution, break
            if (_hasConverged(input.twoCrypto, input.i, input.j, midDx, midDy, input.targetDy)) {
                break;
            }

            if (iterations >= MAX_ITERATIONS_BINSEARCH) {
                revert TwoCryptoNGPreviewLib_SolutionNotFound();
            }
        }
        return midDx;
    }

    /**
     * @dev Returns true if algorithm converged
     * @param twoCrypto PT/YBT curve pool
     * @param i token index, either 0 or 1
     * @param j token index, either 0 or 1, must be different than i
     * @param midDx The current guess for the `dx` value that is being refined through the search process.
     * @param midDy The output of the `get_dy` function for the current guess. `get_dy(i, j, midDx)`
     * @param targetDy The target output of the `get_dy` function, which the search aims to achieve by adjusting `dx`.
     * @return true if the solution to the search problem was found, false otherwise
     */
    function _hasConverged(TwoCrypto twoCrypto, uint256 i, uint256 j, uint256 midDx, uint256 midDy, uint256 targetDy)
        internal
        view
        returns (bool)
    {
        if (midDy == targetDy) return true; // Obvious solution

        uint256 dyNext = twoCrypto.get_dy(i, j, midDx + 1);
        return (midDy < targetDy && targetDy < dyNext);
    }

    /// @notice Convert amount of token A to amount of token B
    function convertTokenAmount(uint256 amountA, uint8 decimalsA, uint8 decimalsB) internal pure returns (uint256) {
        if (decimalsA > decimalsB) {
            return amountA / (10 ** (decimalsA - decimalsB));
        } else {
            return amountA * (10 ** (decimalsB - decimalsA));
        }
    }
}
