// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {Base, TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";

import {ConversionLib} from "src/lens/ConversionLib.sol";
import {Errors} from "src/Errors.sol";
import "src/Types.sol";
import "src/Constants.sol" as Constants;

contract ConversionLibTest is TwoCryptoZapAMMTest {
    function test_EffectivePtPrice() public {
        vm.mockCall(address(principalToken), abi.encodeWithSelector(principalToken.decimals.selector), abi.encode(6));
        vm.mockCall(address(target), abi.encodeWithSelector(target.decimals.selector), abi.encode(18));
        vm.mockCall(
            address(resolver), abi.encodeWithSelector(resolver.scale.selector), abi.encode(10 ** 6 * 10 ** (18 - 18))
        );

        uint256 price = ConversionLib.calculateEffectivePtPrice({
            twoCrypto: twocrypto,
            principal: 1e6,
            shares: 0.89e18,
            kind: ConversionLib.SwapKind.PT
        });
        assertApproxEqRel(price, 0.89e18, 0.0001e18, "PT price should be 0.89");
        uint256 priceYT = ConversionLib.calculateEffectivePtPrice({
            twoCrypto: twocrypto,
            principal: 1e6,
            shares: 0.89e18,
            kind: ConversionLib.SwapKind.YT
        });
        assertApproxEqRel(priceYT, WAD - 0.89e18, 0.0001e18, "YT price should be 1 - pt price");
    }

    function test_NegativeYtPrice() public {
        vm.mockCall(address(resolver), abi.encodeWithSelector(resolver.scale.selector), abi.encode(WAD));
        vm.mockCall(address(principalToken), abi.encodeWithSelector(principalToken.decimals.selector), abi.encode(6));
        vm.mockCall(address(target), abi.encodeWithSelector(target.decimals.selector), abi.encode(18));

        uint256 priceYT = ConversionLib.calculateEffectivePtPrice({
            twoCrypto: twocrypto,
            principal: 1e6,
            shares: 10000e18,
            kind: ConversionLib.SwapKind.YT
        });
        assertEq(priceYT, 0, "YT price should be 0");
    }

    function test_ImpliedApy() public {
        uint256 scale = 1e18;
        uint256 priceInAsset = 0.972e18;
        uint256 timeToExpiry = 365 days / 4;

        vm.warp(expiry - timeToExpiry);
        vm.mockCall(address(resolver), abi.encodeWithSelector(resolver.scale.selector), abi.encode(scale));

        int256 apy = ConversionLib.convertToImpliedAPY({priceInAsset: priceInAsset, timeToExpiry: timeToExpiry});
        assertApproxEqRel(apy, 0.1203e18, 0.0001e18, "implied rate should be 12.03%");
    }

    function test_ZeroImpliedApy() public {
        uint256 scale = 1e18;
        uint256 priceInAsset = 1e18;
        uint256 timeToExpiry = 3930203;

        vm.warp(expiry - timeToExpiry);
        vm.mockCall(address(resolver), abi.encodeWithSelector(resolver.scale.selector), abi.encode(scale));

        int256 apy = ConversionLib.convertToImpliedAPY({priceInAsset: priceInAsset, timeToExpiry: timeToExpiry});
        assertApproxEqRel(apy, 0, 0.0001e18, "implied rate should be 0%");
    }

    function test_ImpliedApy_WhenExpired() public {
        vm.warp(expiry);
        int256 apy = ConversionLib.convertToImpliedAPY({pt: address(principalToken), priceInAsset: 0.972e18});
        assertEq(apy, 0, "implied rate should be 0 (undefined)");
    }

    function test_ImpliedApy_WhenNegative() public {
        uint256 priceInAsset = 12e18; // > 1e18. PT is not discounted.
        uint256 timeToExpiry = 365 days / 5;

        vm.warp(expiry - timeToExpiry);

        int256 apy = ConversionLib.convertToImpliedAPY({priceInAsset: priceInAsset, timeToExpiry: timeToExpiry});
        assertLe(apy, 0, "implied rate should be negative");
    }

    function test_ImpliedApy_WhenZeroPrice() public {
        uint256 priceInAsset = 0;
        uint256 timeToExpiry = 365 days / 4;

        vm.warp(expiry - timeToExpiry);

        int256 apy = ConversionLib.convertToImpliedAPY({priceInAsset: priceInAsset, timeToExpiry: timeToExpiry});
        assertEq(apy, 0, "implied rate should be 0 (undefined)");
    }

    function test_RT_ImpliedAPYToPriceInAsset() public pure {
        int256 impliedAPY = 0.339003e18;
        uint256 timeToExpiry = 365 days / 4;
        uint256 priceInAsset = ConversionLib.convertToPriceInAsset(impliedAPY, timeToExpiry);
        int256 impliedAPY2 = ConversionLib.convertToImpliedAPY(priceInAsset, timeToExpiry);
        assertApproxEqRel(impliedAPY, impliedAPY2, 0.0001e18, "implied rate should be the same");
    }

    function test_EffectivePrice_Decimals() public {
        vm.mockCall(address(base), abi.encodeWithSelector(base.decimals.selector), abi.encode(6));
        vm.mockCall(address(target), abi.encodeWithSelector(target.decimals.selector), abi.encode(18));

        uint256 price = ConversionLib.calculateEffectivePrice({
            tokenIn: Token.wrap(address(base)),
            tokenOut: Token.wrap(address(target)),
            amountIn: 1e6,
            amountOut: 1e18
        });
        assertApproxEqRel(price, 1e18, 0.0001e18, "Effective price decimals should be 1e18");
    }
}
