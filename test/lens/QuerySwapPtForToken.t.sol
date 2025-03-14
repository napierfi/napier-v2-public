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

contract QuerySwapPtForTokenTest is ImpersonatorTest {
    function _test_Query(Token tokenOut, uint256 principal) internal override {
        tokenOut = boundToken(tokenOut);
        principal = bound(principal, 1, principalToken.totalSupply());

        deal(address(principalToken), alice, principal);

        // Run simulation
        uint256 snapshot = vm.snapshot();
        vm.prank(alice);
        (bool s1, bytes memory ret1) = alice.call(
            abi.encodeCall(Impersonator.querySwapPtForToken, (address(zap), quoter, twocrypto, tokenOut, principal))
        );
        vm.revertTo(snapshot); // Revert to before the call
        vm.assume(s1);

        // Get the preview result
        (uint256 preview,,) = abi.decode(ret1, (uint256, uint256, int256));

        TwoCryptoZap.SwapPtParams memory params = TwoCryptoZap.SwapPtParams({
            twoCrypto: twocrypto,
            tokenOut: tokenOut,
            principal: principal,
            receiver: alice,
            amountOutMin: 0,
            deadline: block.timestamp
        });

        _approve(principalToken, alice, address(zap), type(uint256).max);
        vm.prank(alice);
        (bool s2, bytes memory ret2) = address(zap).call(abi.encodeCall(zap.swapPtForToken, (params)));

        assertEq(s1, s2, "s1 != s2");
        uint256 actual = abi.decode(ret2, (uint256));
        assertApproxEqAbs(preview, actual, _delta_, "preview != actual");
    }
}
