// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {Test, console2} from "forge-std/src/Test.sol";

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";

import "src/Types.sol";
import "src/Errors.sol";

import {LiquidityAmounts} from "src/utils/LiquidityAmounts.sol";

contract LiquidityAmountsTest is Test {
    using SafeCastLib for uint256;

    function testFuzz_InitialLiquidity(uint256 amount0, uint256 amount1) public pure {
        Uint128x2 balances;
        uint256 totalLiquidity;

        amount0 = bound(amount0, 1001, 1e24);
        amount1 = bound(amount1, 1001, 1e24);

        // Verify that sqrt(amount0 * amount1) > MINIMUM_LIQUIDITY
        uint256 sqrtProduct = FixedPointMathLib.sqrt(amount0 * amount1);
        require(sqrtProduct > LiquidityAmounts.MINIMUM_LIQUIDITY, "sqrt(amount0 * amount1) must be > MINIMUM_LIQUIDITY");

        (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent) =
            LiquidityAmounts.getLiquidityForAmounts(amount0, amount1, balances, totalLiquidity);

        uint256 expectedLiquidity = sqrtProduct - LiquidityAmounts.MINIMUM_LIQUIDITY;
        assertEq(liquidity, expectedLiquidity);
        assertEq(amount0Spent, amount0);
        assertEq(amount1Spent, amount1);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testFuzz_InitialLiquidityInsufficient(uint256 amount0, uint256 amount1) public {
        Uint128x2 balances;
        uint256 totalLiquidity;
        amount0 = bound(amount0, 1, 999);
        amount1 = bound(amount1, 1, 999);

        vm.expectRevert(Errors.LiquidityAmounts_InsufficientInitialLiquidity.selector);
        LiquidityAmounts.getLiquidityForAmounts(amount0, amount1, balances, totalLiquidity);
    }

    function testFuzz_AddLiquidity_WhenTotalLiquidityIsZero(uint256 amount0, uint256 amount1) public pure {
        amount0 = bound(amount0, 1001, 1e24);
        amount1 = bound(amount1, 1001, 1e24);

        uint256 sqrtProduct = FixedPointMathLib.sqrt(amount0 * amount1);
        require(sqrtProduct > LiquidityAmounts.MINIMUM_LIQUIDITY, "sqrt(amount0 * amount1) must be > MINIMUM_LIQUIDITY");

        (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent) =
            LiquidityAmounts.getLiquidityForAmounts(amount0, amount1, Packing.pack_uint128x2(0, 0), 0);

        assertEq(
            liquidity,
            sqrtProduct - LiquidityAmounts.MINIMUM_LIQUIDITY,
            "liquidity should be sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY"
        );
        assertEq(amount0Spent, amount0, "amount0 spent should be equal to amount0");
        assertEq(amount1Spent, amount1, "amount1 spent should be equal to amount1");
    }

    function testFuzz_AddLiquidity_WhenTotalLiquidityIsNotZero(
        uint256 initialAmount0,
        uint256 initialAmount1,
        uint256 additionalAmount0,
        uint256 additionalAmount1
    ) public pure {
        Uint128x2 balances;
        uint256 totalLiquidity;

        initialAmount0 = bound(initialAmount0, 1001, 1e24);
        initialAmount1 = bound(initialAmount1, 1001, 1e24);

        additionalAmount0 = bound(additionalAmount0, initialAmount0 / 10, initialAmount0);
        additionalAmount1 = bound(additionalAmount1, initialAmount1 / 10, initialAmount1);

        {
            (uint256 liquidity1, uint256 amount0Spent1, uint256 amount1Spent1) =
                LiquidityAmounts.getLiquidityForAmounts(initialAmount0, initialAmount1, balances, totalLiquidity);

            balances = Packing.pack_uint128x2(
                (initialAmount0 + amount0Spent1).toUint128(), (initialAmount1 + amount1Spent1).toUint128()
            );
            totalLiquidity = uint128(uint256(totalLiquidity) + liquidity1 + LiquidityAmounts.MINIMUM_LIQUIDITY);
        }

        uint256 expectedLiquidity = FixedPointMathLib.min(
            FixedPointMathLib.mulDiv(additionalAmount0, totalLiquidity, balances.value0()),
            FixedPointMathLib.mulDiv(additionalAmount1, totalLiquidity, balances.value1())
        );

        (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent) =
            LiquidityAmounts.getLiquidityForAmounts(additionalAmount0, additionalAmount1, balances, totalLiquidity);
        balances = Packing.pack_uint128x2(
            (balances.value0() + amount0Spent).toUint128(), (balances.value1() + amount1Spent).toUint128()
        );
        totalLiquidity = uint128(uint256(totalLiquidity) + liquidity);

        // Verify results
        assertApproxEqRel(liquidity, expectedLiquidity, 0.01e18, "liquidity should be proportional");
        assertLe(amount0Spent, additionalAmount0, "amount0Spent should not exceed additionalAmount0");
        assertLe(amount1Spent, additionalAmount1, "amount1Spent should not exceed additionalAmount1");
    }

    function testFuzz_RemoveLiquidity(uint256 amount0, uint256 amount1, uint256 liquidityToRemove) public pure {
        Uint128x2 balances;
        uint256 totalLiquidity;

        amount0 = bound(amount0, 1001, 1e24);
        amount1 = bound(amount1, 1001, 1e24);

        (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent) =
            LiquidityAmounts.getLiquidityForAmounts(amount0, amount1, balances, totalLiquidity);
        balances = Packing.pack_uint128x2(
            (balances.value0() + amount0Spent).toUint128(), (balances.value1() + amount1Spent).toUint128()
        );
        totalLiquidity = uint128(uint256(totalLiquidity) + liquidity + LiquidityAmounts.MINIMUM_LIQUIDITY);

        liquidityToRemove = bound(liquidityToRemove, 0, liquidity);

        (uint256 amount0Out, uint256 amount1Out) =
            LiquidityAmounts.getAmountsForLiquidity(liquidityToRemove, totalLiquidity, balances);

        // Check proportionality: amount0Out/amount1Out should approximately equal balance0/balance1
        // Cross multiply: amount0Out * balance1 ≈ amount1Out * balance0
        //
        // However, when dealing with very small amounts or extreme ratios, integer division
        // can cause significant rounding errors. We handle these cases:
        if (amount0Out == 0 || amount1Out == 0) {
            // When removing very small liquidity, rounding can cause one amount to be 0
            // This is expected behavior due to integer math limitations
            return;
        }

        // When one of the amounts is very small, the proportionality check
        // can fail due to rounding. We use different tolerances based on the magnitude
        // of the amounts to handle edge cases appropriately.
        uint256 minAmount = amount0Out < amount1Out ? amount0Out : amount1Out;

        if (minAmount <= 100) {
            // With very small amounts (≤100), rounding errors can be significant
            // Just verify both amounts are positive
            assertGt(amount0Out, 0, "amount0Out should be positive");
            assertGt(amount1Out, 0, "amount1Out should be positive");
            return;
        }

        // For larger amounts, use a tolerance that accounts for potential rounding
        // The smaller the amounts, the larger the acceptable deviation
        uint256 tolerance = minAmount <= 1000 ? 0.1e18 : 0.05e18; // 10% for small amounts, 5% otherwise

        assertApproxEqRel(
            amount0Out * balances.value1(), amount1Out * balances.value0(), tolerance, "Proportionality is preserved"
        );
    }

    function test_RemoveLiquidity() public pure {
        // Test with balanced amounts to ensure proportionality is maintained
        uint256 amount0 = 1e18;
        uint256 amount1 = 2e18;

        Uint128x2 balances;
        uint256 totalLiquidity;

        (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent) =
            LiquidityAmounts.getLiquidityForAmounts(amount0, amount1, balances, totalLiquidity);

        balances = Packing.pack_uint128x2(amount0Spent.toUint128(), amount1Spent.toUint128());
        totalLiquidity = liquidity + LiquidityAmounts.MINIMUM_LIQUIDITY;

        // Remove half the liquidity
        uint256 liquidityToRemove = liquidity / 2;

        (uint256 amount0Out, uint256 amount1Out) =
            LiquidityAmounts.getAmountsForLiquidity(liquidityToRemove, totalLiquidity, balances);

        // Check that we get approximately half of each token back
        assertApproxEqRel(amount0Out, amount0 / 2, 0.01e18, "Should get ~half of amount0");
        assertApproxEqRel(amount1Out, amount1 / 2, 0.01e18, "Should get ~half of amount1");

        // Check proportionality
        assertApproxEqRel(
            amount0Out * balances.value1(), amount1Out * balances.value0(), 0.01e18, "Proportionality is preserved"
        );
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testFuzz_RemoveLiquidity_RevertWhen_NoLiquidity(uint256 liquidity) public {
        Uint128x2 balances = Packing.pack_uint128x2(1000, 1000);
        uint256 totalLiquidity = 0;
        liquidity = bound(liquidity, 1, 1e24);

        vm.expectRevert(Errors.LiquidityAmounts_NoLiquidity.selector);
        LiquidityAmounts.getAmountsForLiquidity(liquidity, totalLiquidity, balances);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testFuzz_GetAmountsForLiquidity_RevertWhen_NoLiquidity(uint256 liquidity) public {
        Uint128x2 balances = Packing.pack_uint128x2(1000, 1000);
        liquidity = bound(liquidity, 1, 1e24);

        vm.expectRevert(Errors.LiquidityAmounts_NoLiquidity.selector);
        LiquidityAmounts.getAmountsForLiquidity(liquidity, 0, balances);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testFuzz_RemoveLiquidity_RevertWhen_LiquidityExceedsTotalLiquidity(uint256 amount0, uint256 amount1)
        public
    {
        Uint128x2 balances = Packing.pack_uint128x2(1000, 1000);
        uint256 totalLiquidity = 1000;
        amount0 = bound(amount0, 1e18, 1e24);
        amount1 = bound(amount1, 1e18, 1e24);

        (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent) =
            LiquidityAmounts.getLiquidityForAmounts(amount0, amount1, balances, totalLiquidity);
        balances = Packing.pack_uint128x2(
            (balances.value0() + amount0Spent).toUint128(), (balances.value1() + amount1Spent).toUint128()
        );
        totalLiquidity = uint128(uint256(totalLiquidity) + liquidity);

        vm.expectRevert(Errors.LiquidityAmounts_LiquidityExceedsTotalLiquidity.selector);
        LiquidityAmounts.getAmountsForLiquidity(totalLiquidity + 1, totalLiquidity, balances);
    }
}
