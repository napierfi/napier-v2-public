// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import {LinearPrice} from "src/oracles/LinearPrice.sol";
import "src/Constants.sol" as Constants;

contract LinearPriceTest is Test {
    using FixedPointMathLib for uint256;

    uint256 constant SECONDS_PER_YEAR = LinearPrice.SECONDS_PER_YEAR;
    uint256 constant BASIS_POINTS = Constants.BASIS_POINTS;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     GETDISCOUNTBPS TESTS                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_GetDiscountBps() public {
        uint256 expiry = block.timestamp + 5 * SECONDS_PER_YEAR;
        uint256 discountRatePerYearBps = 1000; // 10%

        // 10% discount rate, starting with 5 years remaining
        {
            // Initially: 5 years remaining = 5 * 10% = 50% discount
            assertEq(LinearPrice.getDiscountBps(expiry, discountRatePerYearBps), 5 * discountRatePerYearBps, "5 years");

            skip(SECONDS_PER_YEAR / 2);
            // After 6 months: 4.5 years remaining = 4.5 * 10% = 45% discount
            assertEq(
                LinearPrice.getDiscountBps(expiry, discountRatePerYearBps), discountRatePerYearBps * 9 / 2, "4.5 years"
            );

            skip(SECONDS_PER_YEAR / 2);
            // After 1 year total: 4 years remaining = 4 * 10% = 40% discount
            assertEq(LinearPrice.getDiscountBps(expiry, discountRatePerYearBps), 4 * discountRatePerYearBps, "4 years");

            skip(SECONDS_PER_YEAR / 2);
            // After 1.5 years total: 3.5 years remaining = 3.5 * 10% = 35% discount
            assertEq(
                LinearPrice.getDiscountBps(expiry, discountRatePerYearBps), discountRatePerYearBps * 7 / 2, "3.5 years"
            );

            skip(SECONDS_PER_YEAR / 2);
            // After 2 years total: 3 years remaining = 3 * 10% = 30% discount
            assertEq(LinearPrice.getDiscountBps(expiry, discountRatePerYearBps), 3 * discountRatePerYearBps, "3 years");

            vm.warp(expiry);
            // At expiry: 0 years remaining = 0% discount
            assertEq(LinearPrice.getDiscountBps(expiry, discountRatePerYearBps), 0, "no discount");

            // Post expiry: 0 years remaining = 0% discount
            skip(1 days);
            assertEq(LinearPrice.getDiscountBps(expiry, discountRatePerYearBps), 0, "post expiry");
        }

        // zero discount
        discountRatePerYearBps = 0;
        assertEq(LinearPrice.getDiscountBps(expiry, discountRatePerYearBps), 0, "zero discount");

        // 100% discount in 1 year
        discountRatePerYearBps = BASIS_POINTS;
        expiry = block.timestamp + SECONDS_PER_YEAR;
        assertEq(LinearPrice.getDiscountBps(expiry, discountRatePerYearBps), BASIS_POINTS, "100% discount");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                 VALIDATE DISCOUNT RATE TESTS                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_ValidateDiscountRatePerYear() public view {
        uint256 expiry = block.timestamp + SECONDS_PER_YEAR;
        uint256 discountRatePerYearBps = 1000; // 10%

        // Should not revert
        LinearPrice.validateDiscountRatePerYear(expiry, discountRatePerYearBps);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_ValidateDiscountRatePerYear_RevertWhen_ZeroRate() public {
        uint256 expiry = block.timestamp + SECONDS_PER_YEAR;
        uint256 discountRatePerYearBps = 0;

        vm.expectRevert(LinearPrice.LinearPrice_InvalidDiscountRatePerYear.selector);
        LinearPrice.validateDiscountRatePerYear(expiry, discountRatePerYearBps);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_ValidateDiscountRatePerYear_RevertWhen_DiscountExceeds100Percent() public {
        uint256 expiry = block.timestamp + 2 * SECONDS_PER_YEAR;
        uint256 discountRatePerYearBps = 5001; // 50.01% per year

        // 2 years * 50% = 100% total discount, should revert
        vm.expectRevert(LinearPrice.LinearPrice_DiscountExceeds100Percent.selector);
        LinearPrice.validateDiscountRatePerYear(expiry, discountRatePerYearBps);
    }
}
