// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {ZapPrincipalTokenTest} from "../shared/Zap.t.sol";
import "../Property.sol" as Property;

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";

import {Token} from "src/Types.sol";
import "src/types/Token.sol" as TokenType;

using {TokenType.intoToken} for address;

contract ZapRedeemTest is ZapPrincipalTokenTest {
    function toyInit() internal returns (Init memory init) {
        init = Init({
            user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [uint256(1e18), 768143, 38934923, 31287],
            principal: [uint256(131311313), 0, 313130, 0],
            yield: int256(1e18)
        });
    }

    function test_RedeemToUnderlying() public {
        Init memory init = toyInit();
        Token token = address(target).intoToken();
        uint256 principal = 10 ** principalToken.decimals();

        FeePcts newFeePcts = FeePctsLib.pack(3000, 10, 10, 100, 333);
        setFeePcts(newFeePcts);

        _test_Redeem(init, token, principal);
    }

    function test_RedeemToBaseAsset() public {
        Init memory init = toyInit();
        Token token = address(base).intoToken();
        uint256 principal = 10 ** principalToken.decimals();

        FeePcts newFeePcts = FeePctsLib.pack(3000, 10, 10, 100, 333);
        setFeePcts(newFeePcts);

        _test_Redeem(init, token, principal);
    }

    function testFuzz_Redeem(Init memory init, Token token, uint256 principal, FeePcts newFeePcts)
        public
        boundInit(init)
    {
        address caller = init.user[0];

        token = boundToken(token);
        principal = bound(principal, 0, principalToken.balanceOf(caller));

        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);

        _test_Redeem(init, token, principal);
    }

    /// @notice Test `redeem` function
    function _test_Redeem(Init memory init, Token token, uint256 principal) internal {
        setUpVault(init);
        vm.warp(expiry + 1000);

        address caller = init.user[0];
        address receiver = init.user[1];

        uint256 oldTokenBalance =
            token.isNative() ? receiver.balance : SafeTransferLib.balanceOf(token.unwrap(), receiver);
        uint256 oldPtBalance = principalToken.balanceOf(caller);
        principal = bound(principal, 0, principalToken.balanceOf(caller));
        _approve(address(principalToken), caller, address(zap), principal);

        vm.prank(caller);
        uint256 amountOut = zap.redeem(principalToken, token, principal, receiver, 0);

        assertEq(oldPtBalance - principalToken.balanceOf(caller), principal, "PT balance mismatch");

        uint256 newTokenBalance =
            token.isNative() ? receiver.balance : SafeTransferLib.balanceOf(token.unwrap(), receiver);
        assertEq(newTokenBalance - oldTokenBalance, amountOut, "Token balance mismatch");

        assertNoFundLeft();
    }

    function test_RevertWhen_BadPrincipalToken() public {
        vm.expectRevert(Errors.Zap_BadPrincipalToken.selector);
        zap.redeem(PrincipalToken(makeAddr("badPrincipalToken")), address(base).intoToken(), 10000, alice, 0);
    }

    function test_RevertWhen_BadToken() public {
        Init memory init = toyInit();
        setUpVault(init);
        vm.warp(expiry + 1000);
        address caller = init.user[0];
        vm.startPrank(caller);
        principalToken.approve(address(zap), type(uint256).max);
        vm.expectRevert(Errors.ERC4626Connector_InvalidToken.selector);
        zap.redeem(principalToken, address(0xcafe).intoToken(), 1000, caller, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_SlippageTooLarge() public {
        Init memory init = toyInit();
        setUpVault(init);
        vm.warp(expiry + 1000);
        address caller = init.user[0];
        vm.startPrank(caller);
        principalToken.approve(address(zap), type(uint256).max);
        vm.expectRevert(Errors.Zap_InsufficientTokenOutput.selector);
        zap.redeem(principalToken, address(target).intoToken(), 100, alice, 10000);
        vm.stopPrank();
    }
}

contract ZapRedeemETHTest is ZapRedeemTest {
    function _deployTokens() internal override {
        _deployWETHVault();
    }

    function validTokenInput() internal view override returns (address[] memory tokens) {
        tokens = new address[](3);
        tokens[0] = address(target);
        tokens[1] = address(base);
        tokens[2] = NATIVE_ETH;
    }

    function test_RedeemToNativeETH() public {
        Init memory init = toyInit();
        Token token = Token.wrap(NATIVE_ETH);
        uint256 principal = 10 ** principalToken.decimals();

        _test_Redeem(init, token, principal);
    }
}
