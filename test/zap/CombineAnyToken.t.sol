// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {ZapForkTest} from "../shared/Fork.t.sol";

import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import "src/Types.sol";
import "src/Constants.sol" as Constants;
import {RouterPayload} from "src/modules/aggregator/AggregationRouter.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";

using {TokenType.intoToken} for address;

contract ZapCombineToAnyTokenTest is ZapForkTest {
    /// @notice 1inch payload for swapping ETH to USDC
    bytes constant ONEINCH_SWAP_CALL_DATA =
        hex"175accdc0000000000000000000000001d96f2f6bef1202e4ce1ff6dad0c2cb002861d3e000000000000000000000000000000000000000000000000000000008e01b49c200000000000000000000000e0554a476a092703abdb3ef35c80e0d76d32939f9432a17f";

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 21075108);
    }

    function setUp() public override {
        super.setUp();

        deal(WETH, alice, 1000e18, false);
        _approve(WETH, alice, address(zap), 1000e18);
        vm.prank(alice);
        zap.supply{value: 0}(principalToken, WETH, 1000e18, alice, 0);
    }

    function toySwapOutput() internal pure returns (TwoCryptoZap.SwapTokenOutput memory) {
        RouterPayload memory swapData = RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_SWAP_CALL_DATA});
        return TwoCryptoZap.SwapTokenOutput({tokenRedeemShares: NATIVE_ETH.intoToken(), swapData: swapData});
    }

    /// @notice PT + YT -> shares -> native ETH -> [1inch] -> USDC
    function test_Combine() public {
        Token tokenOut = USDC;
        uint256 principal = 1e18;

        FeePcts newFeePcts = FeePctsLib.pack(3000, 1021, 10, 100, 2122);
        setFeePcts(newFeePcts);

        _test_Combine(alice, bob, tokenOut, principal);
    }

    /// @notice Test `combineToAnyToken` function
    function _test_Combine(address caller, address receiver, Token token, uint256 principal) internal {
        uint256 oldTokenBalance = token.isNative() ? receiver.balance : token.erc20().balanceOf(receiver);

        uint256 ytBalance = yt.balanceOf(caller);
        uint256 ptBalance = principalToken.balanceOf(caller);

        principal = bound(principal, 0, FixedPointMathLib.min(ptBalance, ytBalance));

        _approve(principalToken, caller, address(zap), principal);
        _approve(yt, caller, address(zap), principal);
        vm.prank(caller);
        uint256 amountOut = zap.combineToAnyToken(
            principalToken,
            token,
            principal,
            receiver,
            0, // minAmount
            toySwapOutput()
        );

        uint256 newTokenBalance = token.isNative() ? receiver.balance : token.erc20().balanceOf(receiver);

        assertGt(amountOut, 0, "Amount out > 0");
        assertEq(yt.balanceOf(caller) + principal, ytBalance, "YT mismatch");
        assertEq(principalToken.balanceOf(caller) + principal, ptBalance, "PT mismatch");
        assertEq(newTokenBalance, oldTokenBalance + amountOut, "Token out mismatch");
        assertNoFundLeft();
    }

    function test_RevertWhen_BadPrincipalToken() public {
        vm.expectRevert(Errors.Zap_BadPrincipalToken.selector);
        zap.combineToAnyToken(PrincipalToken(makeAddr("badPrincipalToken")), USDC, 10000, alice, 0, toySwapOutput());
    }

    function test_RevertWhen_InsufficientPTAllowance() public {
        address caller = alice;
        uint256 principal = 10000;

        deal(address(principalToken), caller, principal);
        deal(address(yt), caller, principal);

        // Only approve YT, not PT
        _approve(yt, caller, address(zap), principal);

        vm.expectRevert();
        vm.prank(caller);
        zap.combineToAnyToken(principalToken, USDC, principal, alice, 0, toySwapOutput());
    }

    function test_RevertWhen_InsufficientYTAllowance() public {
        address caller = alice;
        uint256 principal = 10000;

        deal(address(principalToken), caller, principal);
        deal(address(yt), caller, principal);

        // Only approve PT, not YT
        _approve(principalToken, caller, address(zap), principal);

        vm.expectRevert();
        vm.prank(caller);
        zap.combineToAnyToken(principalToken, USDC, principal, alice, 0, toySwapOutput());
    }

    function test_RevertWhen_SlippageTooLarge() public {
        address caller = alice;
        uint256 amount = 1e18;
        Token token = address(target).intoToken();

        // Supply first
        deal(token, caller, amount);
        _approve(token.unwrap(), caller, address(zap), amount);

        vm.prank(caller);
        uint256 ptReceived = zap.supply(principalToken, token, amount, caller, 0);

        _approve(principalToken, caller, address(zap), ptReceived);
        _approve(yt, caller, address(zap), ptReceived);

        vm.expectRevert(Errors.Zap_InsufficientTokenOutput.selector);
        vm.prank(caller);
        zap.combineToAnyToken(
            principalToken,
            USDC,
            ptReceived,
            bob,
            type(uint256).max, // Incredibly large minAmount to trigger slippage error
            toySwapOutput()
        );
    }
}
