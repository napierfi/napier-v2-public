// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {Base} from "../Base.t.sol";
import {ImpersonatorTest} from "./Impersonator.t.sol";

import {Impersonator} from "src/lens/Impersonator.sol";
import {ConversionLib} from "src/lens/ConversionLib.sol";

import "src/Types.sol";
import "src/Constants.sol";

contract QueryInitialPriceTest is ImpersonatorTest {
    function test_Query() public {
        setUpYield(int256(target.totalAssets() / 86));

        bytes memory resolverArgs = abi.encode(target); // Add appropriate resolver args if needed
        int256 impliedAPY = 0.12038e18; // 12.038%

        // Run simulation
        uint256 snapshot = vm.snapshot();
        vm.prank(alice);
        (bool success, bytes memory ret) = alice.call(
            abi.encodeCall(
                Impersonator.queryInitialPrice, (address(zap), expiry, impliedAPY, resolver_blueprint, resolverArgs)
            )
        );
        vm.revertTo(snapshot); // Revert to before the call
        vm.assume(success);

        // Get the result
        uint256 initialPrice = abi.decode(ret, (uint256));

        // Invert the formula
        uint256 scale = resolver.scale();
        uint256 assetDecimals = resolver.assetDecimals();
        uint256 underlyingDecimals = resolver.decimals();
        int256 result = ConversionLib.convertToImpliedAPY({
            priceInAsset: initialPrice * scale / 10 ** (18 + assetDecimals - underlyingDecimals),
            timeToExpiry: expiry - block.timestamp
        });

        assertApproxEqRel(result, impliedAPY, 0.001e18, "Mismatch");
    }

    function testFuzz_Query(SetupAMMFuzzInput memory, /* input */ Token, /* token */ uint256 /* shares */ )
        public
        override
    {
        vm.skip(true);
    }

    /// @dev Not suitable for the target function
    function _test_Query(Token, /* token */ uint256 /* shares */ ) internal override {}

    function test_RevertWhen_ExpiryIsInThePast() public {
        vm.expectRevert(Impersonator.Impersonator_ExpiryIsInThePast.selector);
        Impersonator(payable(alice)).queryInitialPrice(
            address(zap), block.timestamp - 1, 1e18, resolver_blueprint, abi.encode(target)
        );
    }

    function test_RevertWhen_InvalidResolverBlueprint() public {
        vm.expectRevert(Impersonator.Impersonator_InvalidResolverBlueprint.selector);
        Impersonator(payable(alice)).queryInitialPrice(address(zap), expiry, 1e18, address(0xcafeeee), "hoge");
    }

    function test_RevertWhen_InvalidResolverConfig() public {
        vm.expectRevert(Impersonator.Impersonator_InvalidResolverConfig.selector);
        Impersonator(payable(alice)).queryInitialPrice(
            address(zap),
            expiry,
            1e18,
            resolver_blueprint,
            abi.encode(address(0xcafe)) // Bad vault address
        );

        vm.mockCallRevert(
            address(target),
            abi.encodeWithSelector(target.convertToAssets.selector),
            abi.encode(unicode"くぁwせdrftgyふじこlp")
        );
        vm.expectRevert(Impersonator.Impersonator_InvalidResolverConfig.selector);
        Impersonator(payable(alice)).queryInitialPrice(
            address(zap),
            expiry,
            1e18,
            resolver_blueprint,
            abi.encode(target) // `convertToAssets` behaves wrong
        );
    }
}
