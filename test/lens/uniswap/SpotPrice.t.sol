// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {ZapSwapTest} from "../../zap/uniswap/SwapYT.t.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import {TokiQuoter} from "src/lens/uniswap/TokiQuoter.sol";
import {TokiSwap} from "src/utils/TokiSwap.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

/// @title SpotPrice Test Suite
/// @notice Tests for TokiQuoter convertPtTo functions with comprehensive coverage
/// @dev Focuses on convertPtToUnderlying and convertPtToAssets functions
contract SpotPriceTest is ZapSwapTest {
    using SafeCastLib for *;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           SETUP                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function setUp() public override {
        super.setUp();

        // Initial liquidity is already set up in ZapSwapTest
        // Just add some trading activity to establish realistic pricing
        _swap({user: alice, zeroForOne: false, amount: -int256(100 * bOne), timeJump: 0});
        _swap({user: alice, zeroForOne: true, amount: int256(50 * bOne), timeJump: 1 minutes});

        require(target.convertToAssets(tOne) > bOne, "vault share price should be > 1");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     FOUNDATION TESTS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Test basic PT to underlying conversion functionality
    function test_ConvertPtToUnderlying_WhenPreExpiry() public view {
        uint256 principals = 78219090921909;

        uint256 shares = quoter.convertPtToUnderlying(poolKey, principals);

        // Basic sanity checks
        assertGt(shares, 0, "Should return positive underlying amount");
        assertLt(shares, principals, "Pre-expiry PT should be worth less than face value");

        assertApproxEqAbs(shares, target.convertToShares(quoter.convertPtToAssets(poolKey, principals)), 5);

        assertEq(quoter.convertPtToUnderlying(poolKey, 0), 0);
    }

    function test_ConvertPtToUnderlying_WhenPostExpiry() public {
        vm.warp(expiry);

        uint256 principals = 9980890210231219;
        uint256 shares = quoter.convertPtToUnderlying(poolKey, principals);

        assertApproxEqAbs(shares, principalToken.convertToUnderlying(principals), 5);
        assertEq(quoter.convertPtToUnderlying(poolKey, 0), 0);
    }

    function test_ConvertPtToAssets_WhenPreExpiry() public view {
        uint256 principals = 1000 * bOne;

        uint256 assets = quoter.convertPtToAssets(poolKey, principals);

        // Basic sanity checks
        assertGt(assets, 0, "Should return positive assets amount");
        assertLt(assets, principals, "Pre-expiry PT should be worth less than face value");

        // Should be reasonable relative to stored rate
        uint256 lnImpliedRate = stateOf(poolKey.toId()).lnImpliedRate;
        int256 assetToPtRate = TokiSwap.convertToExchangeRate(lnImpliedRate, expiry - block.timestamp);
        uint256 assetsApprox = Constants.WAD * principals / assetToPtRate.toUint256();

        assertApproxEqRel(assets, assetsApprox, 0.001e18, "Should be close to stored rate");

        assertEq(quoter.convertPtToAssets(poolKey, 0), 0);
    }

    function test_ConvertPtToAssets_WhenPostExpiry() public {
        vm.warp(expiry);

        uint256 principals = 9980890210231219;
        uint256 assets = quoter.convertPtToAssets(poolKey, principals);

        assertApproxEqAbs(assets, target.convertToAssets(principalToken.convertToUnderlying(principals)), 5);
        assertEq(quoter.convertPtToAssets(poolKey, 0), 0);
    }

    function test_ConvertPt_WhenUninitializedPool() public {
        vm.skip(true);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    YT CONVERSION TESTS                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_ConvertYtToUnderlying_WhenPreExpiry() public view {
        uint256 principals = 303920;
        uint256 shares = quoter.convertYtToUnderlying(poolKey, principals);
        assertApproxEqAbs(shares, target.convertToShares(quoter.convertYtToAssets(poolKey, principals)), 5);
    }

    function test_ConvertYtToAssets_WhenPreExpiry() public view {
        uint256 principals = 303920;

        uint256 ytAssets = quoter.convertYtToAssets(poolKey, principals);
        uint256 ptAssets = quoter.convertPtToAssets(poolKey, principals);

        // Basic sanity checks
        assertGt(ytAssets, 0, "Should return positive YT assets amount");
        assertLt(ytAssets, principals, "Pre-expiry YT should be worth less than face value");

        // Core relationship: YT + PT = Principal
        assertEq(ytAssets + ptAssets, principals, "YT + PT should equal principals");

        // Zero input should return zero
        assertEq(quoter.convertYtToAssets(poolKey, 0), 0, "Zero input should return zero");
    }

    function test_ConvertYtToAssets_WhenPostExpiry() public {
        vm.warp(expiry);

        uint256 principals = 303920;
        uint256 assets = quoter.convertYtToAssets(poolKey, principals);

        // Post-expiry, YT should be worthless (all value is in PT if underlying token doesn't experience loss)
        assertEq(assets, 0, "Post-expiry YT should be worthless");
        assertEq(quoter.convertYtToAssets(poolKey, 0), 0, "Zero YT should return zero post-expiry");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    LP CONVERSION TESTS                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_ConvertLpToAssets_WhenPreExpiry() public view {
        uint256 totalLiquidity = stateOf(poolKey.toId()).totalLiquidity;
        uint256 liquidity = totalLiquidity / 100; // Use 1% of total liquidity for testing

        Uint128x2 balances = tokiHook.getTotalBalances(poolKey.toId());
        uint256 lpAssets = quoter.convertLpToAssets(poolKey, liquidity);

        // Calculate expected value: proportion of total redeemable assets
        uint256 balances0InAsset = target.convertToAssets(balances.value0());
        uint256 balances1InAsset = quoter.convertPtToAssets(poolKey, balances.value1());
        uint256 totalRedeemableAssets = balances0InAsset + balances1InAsset;
        uint256 expectedLpAssets = totalRedeemableAssets * liquidity / totalLiquidity;

        // Core relationship: LP should be proportional to total redeemable assets
        assertApproxEqRel(lpAssets, expectedLpAssets, 0.001e18, "LP should be proportional to total redeemable assets");

        // Zero input should return zero
        assertEq(quoter.convertLpToAssets(poolKey, 0), 0, "Zero input should return zero");
    }

    function test_ConvertLpToAssets_WhenPostExpiry() public {
        vm.warp(expiry);

        uint256 totalLiquidity = stateOf(poolKey.toId()).totalLiquidity;
        uint256 liquidity = totalLiquidity / 50; // Use 2% of total liquidity for testing

        uint256 lpAssets = quoter.convertLpToAssets(poolKey, liquidity);
        Uint128x2 balances = tokiHook.getTotalBalances(poolKey.toId());

        // Calculate expected value: proportion of total redeemable assets
        uint256 balances0InAsset = target.convertToAssets(balances.value0());
        uint256 balances1InAsset = quoter.convertPtToAssets(poolKey, balances.value1());
        uint256 totalRedeemableAssets = balances0InAsset + balances1InAsset;
        uint256 expectedLpAssets = totalRedeemableAssets * liquidity / totalLiquidity;

        assertApproxEqRel(
            lpAssets, expectedLpAssets, 0.001e18, "LP should be proportional to total redeemable assets post-expiry"
        );
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   IMPLIED RATE WAD TESTS                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_ImpliedRateWad_WhenPreExpiry() public view {
        int256 impliedRateWad = quoter.getImpliedRateWad(poolKey);

        uint256 lnImpliedRate = stateOf(poolKey.toId()).lnImpliedRate;
        int256 irStored = FixedPointMathLib.expWad(lnImpliedRate.toInt256()) - TokiSwap.IWAD;

        assertApproxEqRel(impliedRateWad, irStored, 0.0001e18, "Implied rate should be close to stored rate");
    }

    function test_ImpliedRateWad_WhenPostExpiry() public {
        vm.warp(expiry);

        int256 impliedRateWad = quoter.getImpliedRateWad(poolKey);
        assertEq(impliedRateWad, 0);
    }

    function test_ImpliedRateWad_RevertWhen_InvalidPool() public {
        // Create pool key with non-existent currencies
        PoolKey memory invalidKey = PoolKey({
            currency0: Currency.wrap(address(0x1234)),
            currency1: Currency.wrap(address(0x5678)),
            fee: poolKey.fee,
            tickSpacing: poolKey.tickSpacing,
            hooks: poolKey.hooks
        });

        vm.expectRevert(Errors.BadTokiPool.selector);
        quoter.getImpliedRateWad(invalidKey);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      ERROR CONDITIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_RevertWhen_BadPool() public override {
        // Create pool key with non-existent currencies
        PoolKey memory invalidKey = PoolKey({
            currency0: Currency.wrap(address(0x1234)),
            currency1: Currency.wrap(address(0x5678)),
            fee: poolKey.fee,
            tickSpacing: poolKey.tickSpacing,
            hooks: poolKey.hooks
        });

        // PT
        vm.expectRevert(Errors.BadTokiPool.selector);
        quoter.convertPtToUnderlying(invalidKey, 2312311231);

        vm.expectRevert(Errors.BadTokiPool.selector);
        quoter.convertPtToAssets(invalidKey, 9093231231);

        // YT
        vm.expectRevert(Errors.BadTokiPool.selector);
        quoter.convertYtToUnderlying(invalidKey, 231231);

        vm.expectRevert(Errors.BadTokiPool.selector);
        quoter.convertYtToAssets(invalidKey, 231231);

        // LP
        vm.expectRevert(Errors.BadTokiPool.selector);
        quoter.convertLpToUnderlying(invalidKey, 312300);

        vm.expectRevert(Errors.BadTokiPool.selector);
        quoter.convertLpToAssets(invalidKey, 0);
    }
}
