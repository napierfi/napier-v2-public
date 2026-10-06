/// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";
import {LiquidityHookBase} from "../hooks/LiquidityHookBase.t.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

import {TWAPPrice} from "../../src/oracles/TWAPPrice.sol";

abstract contract TWAPPriceTest is LiquidityHookBase {
    uint16 constant DEFAULT_CARDINALITY = 100;
    uint32 constant DEFAULT_TWAP_WINDOW = 1800; // 30 minutes

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           SETUP                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function setUp() public override {
        super.setUp();

        INITIAL_AMOUNT0 = 1000 * tOne;
        INITIAL_AMOUNT1 = 1000 * bOne;

        // Add initial liquidity to create a functioning pool
        _addInitialLiquidity(alice, alice);

        tokiHook.increaseObservationsCardinalityNext(poolKey, DEFAULT_CARDINALITY);

        // Ensure we have enough historical data for TWAP calculations
        // Need at least DEFAULT_TWAP_WINDOW (30 minutes) of data
        _swap({user: alice, zeroForOne: false, amount: -1000, timeJump: 0});
        _swap({user: alice, zeroForOne: true, amount: 500, timeJump: 10 minutes});
        _swap({user: alice, zeroForOne: false, amount: -500, timeJump: 10 minutes});
        _swap({user: alice, zeroForOne: true, amount: 1000, timeJump: 15 minutes});

        // Pump up the vault share price
        deal(address(base), curator, 1100 * bOne);
        _approve(address(base), curator, address(target), type(uint256).max);
        vm.prank(curator);
        target.deposit(1000 * bOne, alice);
        vm.prank(curator);
        base.transfer(address(target), 100 * bOne);

        require(target.convertToAssets(tOne) > bOne, "vault share price");

        console.log("target.convertToAssets(tOne)", target.convertToAssets(tOne));
        console.log("totalLiquidity", stateOf(poolKey.toId()).totalLiquidity);
        console.log("balances0", tokiHook.getTotalBalances(poolKey.toId()).value0());
        console.log("balances1", tokiHook.getTotalBalances(poolKey.toId()).value1());
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        RICE TESTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_PtToAssets() public view {
        uint256 spotAssets = TWAPPrice.convertPtToAssets(pool, 0, bOne);
        uint256 twapAssets = TWAPPrice.convertPtToAssets(pool, DEFAULT_TWAP_WINDOW, bOne);

        console.log("spotAssets", spotAssets);
        console.log("twapAssets", twapAssets);

        assertGt(spotAssets, 0, "spotAssets > 0");
        assertLe(spotAssets, bOne, "spotAssets <= 1 asset");
        assertGt(twapAssets, 0, "twapAssets > 0");
        assertLe(twapAssets, bOne, "twapAssets <= 1 asset");

        assertApproxEqRel(spotAssets, twapAssets, 0.0001e18, "spotAssets ~= twapAssets");

        uint256 conversionRate = target.convertToAssets(tOne);
        assertApproxEqAbs(
            spotAssets, conversionRate, conversionRate / 2, "conversionRate/2 < spotAssets < conversionRate * 3/2"
        );
        assertApproxEqAbs(
            twapAssets, conversionRate, conversionRate / 2, "conversionRate/2 < twapAssets < conversionRate * 3/2"
        );
    }

    function test_PtToUnderlying() public view {
        uint256 spotUnderlying = TWAPPrice.convertPtToUnderlying(pool, 0, bOne);
        uint256 twapUnderlying = TWAPPrice.convertPtToUnderlying(pool, DEFAULT_TWAP_WINDOW, bOne);

        console.log("spotUnderlying", spotUnderlying);
        console.log("twapUnderlying", twapUnderlying);

        assertGt(spotUnderlying, 0, "spotUnderlying > 0");
        assertLe(spotUnderlying, tOne, "spotUnderlying <= 1 underlying");
        assertGt(twapUnderlying, 0, "twapUnderlying > 0");
        assertLe(twapUnderlying, tOne, "twapUnderlying <= 1 underlying");

        assertApproxEqRel(spotUnderlying, twapUnderlying, 0.0001e18, "spotUnderlying ~= twapUnderlying");

        uint256 conversionRate = target.convertToShares(bOne);
        assertApproxEqAbs(
            spotUnderlying,
            conversionRate,
            conversionRate / 2,
            "conversionRate/2 < spotUnderlying < conversionRate * 3/2"
        );
        assertApproxEqAbs(
            twapUnderlying,
            conversionRate,
            conversionRate / 2,
            "conversionRate/2 < twapUnderlying < conversionRate * 3/2"
        );
    }

    function test_PtToAssets_WhenExpired() public {
        vm.warp(expiry + 1);

        // After expiry, PT should be redeemable 1:1 for asset
        uint256 principals = 8419414141;
        assertEq(TWAPPrice.convertPtToAssets(pool, DEFAULT_TWAP_WINDOW, principals), principals);
    }

    function test_YtToUnderlying() public {
        vm.skip(true);
    }

    function test_YtToAssets() public view {
        uint256 spotAssets = TWAPPrice.convertYtToAssets(pool, 0, bOne);
        uint256 twapAssets = TWAPPrice.convertYtToAssets(pool, DEFAULT_TWAP_WINDOW, bOne);

        assertGt(spotAssets, 0, "spotAssets > 0");
        assertLe(spotAssets, bOne, "spotAssets <= 1 asset");
        assertGt(twapAssets, 0, "twapAssets > 0");
        assertLe(twapAssets, bOne, "twapAssets <= 1 asset");

        assertApproxEqRel(spotAssets, twapAssets, 0.0001e18, "spotAssets ~= twapAssets");

        uint256 principals = 8419414141;
        assertApproxEqRel(
            TWAPPrice.convertPtToAssets(pool, DEFAULT_TWAP_WINDOW, principals)
                + TWAPPrice.convertYtToAssets(pool, DEFAULT_TWAP_WINDOW, principals),
            principals,
            0.001e18,
            "PT + YT"
        );
    }

    function test_YtToAssets_WhenExpired() public {
        vm.warp(expiry + 1);

        // After expiry, YT should have no value
        assertEq(TWAPPrice.convertYtToAssets(pool, DEFAULT_TWAP_WINDOW, 31384919047321), 0);
    }

    function test_LpToAssets() public view {
        _test_LpToAssets();
    }

    function test_LpToAssets_WhenExpired() public {
        vm.warp(expiry + 1);

        _test_LpToAssets();
    }

    function _test_LpToAssets() internal view {
        // Simple NAV calculation
        uint256 totalAssets = _totalAssetsInPool();
        uint256 totalLiquidity = stateOf(poolKey.toId()).totalLiquidity;

        console.log("totalAssets", totalAssets);
        console.log("totalLiquidity", totalLiquidity);

        uint256 assets = TWAPPrice.convertLpToAssets(pool, DEFAULT_TWAP_WINDOW, 1 ether);
        console.log("assets", assets);
        assertApproxEqRel(assets, totalAssets * 1 ether / totalLiquidity, 0.1e18, "LP to asset rate");
    }

    function test_LpToUnderlying() public view {
        uint256 totalAssets = _totalAssetsInPool();

        uint256 shares = TWAPPrice.convertLpToUnderlying(pool, DEFAULT_TWAP_WINDOW, 1 ether);
        uint256 totalLiquidity = stateOf(poolKey.toId()).totalLiquidity;
        console.log("shares", shares);

        assertApproxEqRel(
            shares, target.convertToShares(totalAssets) * 1 ether / totalLiquidity, 0.1e18, "LP to shares rate"
        );
    }

    function _totalAssetsInPool() internal view returns (uint256) {
        Uint128x2 balances = tokiHook.getTotalBalances(poolKey.toId());
        uint256 totalUnderlying = balances.value0() + principalToken.convertToUnderlying(balances.value1());
        return target.convertToAssets(totalUnderlying);
    }

    function test_Revert_WhenReentrant() public {
        vm.mockCallRevert(
            address(principalToken), principalToken.isSettled.selector, abi.encodeWithSelector(0xab143c06)
        ); // Reentrancy()

        vm.expectRevert(bytes4(0xab143c06)); // Reentrancy()
        this._getTwapLnImpliedRate();
    }

    function _getTwapLnImpliedRate() external view returns (uint256) {
        return TWAPPrice._getTwapLnImpliedRate(poolKey, DEFAULT_TWAP_WINDOW);
    }
}

contract TWAPPrice_LowLowDecimals_Test is TWAPPriceTest {}

contract TWAPPrice_HighLowDecimals_Test is TWAPPriceTest {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           SETUP                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _deployTokens() internal override {
        randomToken = new MockERC20({_decimals: 6});
        base = new MockERC20({_decimals: 6});
        target = new MockERC4626({_asset: base, useVirtualShares: true});
        // High-low decimals
        require(base.decimals() == 6, "base decimals");
        require(target.decimals() == 18, "target decimals");
    }
}
