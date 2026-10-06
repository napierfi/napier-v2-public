// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import "../Types.sol";
import "../Constants.sol" as Constants;

/// @notice Linear Discount model
/// @dev Important security note:
/// - Price oracle could be off if a curator is not trusted
/// - Discount rate is not checked for validity
library LinearPrice {
    uint256 constant SECONDS_PER_YEAR = 365 days;

    error LinearPrice_InvalidDiscountRatePerYear();
    error LinearPrice_DiscountExceeds100Percent();

    /// @notice Get the current discount rate in basis points (discount > 0)
    function getDiscountBps(uint256 expiry, uint256 discountRatePerYearBps) internal view returns (uint256) {
        uint256 timeToExpiry = FixedPointMathLib.zeroFloorSub(expiry, block.timestamp); // max(0, expiry - block.timestamp)
        return (timeToExpiry * discountRatePerYearBps) / SECONDS_PER_YEAR;
    }

    function validateDiscountRatePerYear(uint256 expiry, uint256 discountRatePerYearBps) internal view {
        // No discount rate
        if (discountRatePerYearBps == 0) revert LinearPrice_InvalidDiscountRatePerYear();

        // You can't discount something by more than 100%
        if (((expiry - block.timestamp) * discountRatePerYearBps) / SECONDS_PER_YEAR >= Constants.BASIS_POINTS) {
            revert LinearPrice_DiscountExceeds100Percent();
        }
    }
}
