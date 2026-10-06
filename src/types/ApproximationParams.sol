// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Parameters for the binary search algorithm
/// @dev If eps is zero, the binary search will use default binary search configuration.
/// @param guessMin The minimum value of the guess
/// @param guessMax The maximum value of the guess (guessMin < guessMax)
/// @param eps The relative error tolerance (0.01e18 = 1%). Binary search will run until the relative error is less than eps.
struct ApproximationParams {
    int256 guessMin;
    int256 guessMax;
    uint256 eps;
}

function decodeApproximationParams(bytes calldata a) pure returns (int256 guessMin, int256 guessMax, uint256 eps) {
    assembly {
        // If length is zero, we return zeros
        if iszero(iszero(a.length)) {
            if lt(a.length, 0x60) {
                mstore(0x00, 0xbe8337b0) // ApproximationParams_OutOfBounds()
                revert(0x1c, 0x04)
            }
            guessMin := calldataload(a.offset)
            guessMax := calldataload(add(a.offset, 0x20))
            eps := calldataload(add(a.offset, 0x40))
        }
    }
}

function decodeApproximationParamsStruct(bytes calldata a) pure returns (ApproximationParams memory params) {
    (params.guessMin, params.guessMax, params.eps) = decodeApproximationParams(a);
}

function isEpsZero(ApproximationParams memory params) pure returns (bool) {
    return params.eps == 0;
}
