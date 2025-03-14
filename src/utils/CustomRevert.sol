// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

/// @notice Forked from https://github.com/Uniswap/v4-core/blob/c8173143cf1e6f1c6c7b682a3563b263f149255f/src/libraries/CustomRevert.sol
/// @title Library for reverting with custom errors efficiently
/// @notice Contains functions for reverting with custom errors with different argument types efficiently
/// @dev To use this library, declare `using CustomRevert for bytes4;` and replace `revert CustomError()` with
/// `CustomError.selector.revertWith()`
/// @dev The functions may tamper with the free memory pointer but it is fine since the call context is exited immediately
library CustomRevert {
    /// @dev Reverts with the selector of a custom error in the scratch space
    function revertWith(bytes4 selector) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            revert(0, 0x04)
        }
    }

    function revertWith(bytes4 selector, uint256 value) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            mstore(0x04, value)
            revert(0, 0x24)
        }
    }
}
