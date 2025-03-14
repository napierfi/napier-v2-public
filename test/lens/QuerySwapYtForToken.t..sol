// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {Base} from "../Base.t.sol";
import {ImpersonatorTest} from "./Impersonator.t.sol";

import {Impersonator} from "src/lens/Impersonator.sol";
import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";

import {Errors} from "src/Errors.sol";
import "src/Types.sol";
import "src/Constants.sol";

contract QuerySwapYtForTokenTest is ImpersonatorTest {
    function _test_Query(Token tokenOut, uint256 principal) internal override {
        uint256 errorMarginBps = 100;
        tokenOut = boundToken(tokenOut);
        principal = bound(principal, 1, yt.totalSupply());

        deal(address(yt), alice, principal);

        // Run simulation
        uint256 snapshot = vm.snapshot();
        vm.prank(alice);
        (bool s1, bytes memory ret1) = alice.call(
            abi.encodeCall(
                Impersonator.querySwapYtForToken, (address(zap), quoter, twocrypto, tokenOut, principal, errorMarginBps)
            )
        );
        if (!s1) {
            // Note we don't expect these slippage errors to happen because impersonator runs preview and simulate swaps based on preview results in a single call.
            assertNotEq(
                bytes4(ret1),
                Errors.Zap_InsufficientUnderlyingOutput.selector,
                "unexpected insufficient underlying output"
            );
            assertNotEq(
                bytes4(ret1), Errors.Zap_InsufficientTokenOutput.selector, "unexpected insufficient token output"
            );
        }
        vm.revertTo(snapshot); // Revert to before the call
        vm.assume(s1);

        // Get the preview result
        (
            uint256 amountOutPreview, /*  uint256 ytSpentPreview */
            ,
            ApproxValue dxResultWithMargin, /*  uint256 priceInAsset */
            , /* int256 impliedApy */
        ) = abi.decode(ret1, (uint256, uint256, ApproxValue, uint256, int256));

        TwoCryptoZap.SwapYtParams memory params = TwoCryptoZap.SwapYtParams({
            twoCrypto: twocrypto,
            tokenOut: tokenOut,
            principal: principal,
            receiver: address(this),
            amountOutMin: 0,
            deadline: block.timestamp
        });

        _approve(yt, alice, address(zap), type(uint256).max);
        vm.prank(alice);
        (bool s2, bytes memory ret2) =
            address(zap).call(abi.encodeCall(zap.swapYtForToken, (params, dxResultWithMargin)));

        assertEq(s1, s2, "s1 != s2");
        uint256 actual = abi.decode(ret2, (uint256));
        assertApproxEqAbs(amountOutPreview, actual, _delta_, "preview != actual");
    }
}
