// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {ZapPrincipalTokenTest} from "../shared/Zap.t.sol";
import "../Property.sol" as Property;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";

import {Token} from "src/Types.sol";
import "src/types/Token.sol" as TokenType;

using {TokenType.intoToken} for address;

contract ZapCombineTest is ZapPrincipalTokenTest {
    function toyInit() internal returns (Init memory init) {
        init = Init({
            user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [uint256(1e18), 768143, 38934923, 31287],
            principal: [uint256(131311313), 0, 313130, 0],
            yield: int256(1e18)
        });
    }

    function test_CombineToUnderlying() public {
        Init memory init = toyInit();
        setUpVault(init);

        uint256 amount = init.principal[0];

        FeePcts newFeePcts = FeePctsLib.pack(3000, 10, 10, 100, BASIS_POINTS);
        setFeePcts(newFeePcts);

        _test_Combine(init, address(target).intoToken(), amount);
    }

    function test_CombineToBaseAsset() public {
        Init memory init = toyInit();
        setUpVault(init);

        uint256 amount = init.principal[0] / 2024;

        FeePcts newFeePcts = FeePctsLib.pack(3000, 1021, 909, 100, 2120);
        setFeePcts(newFeePcts);

        vm.warp(expiry + 1);

        _test_Combine(init, address(base).intoToken(), amount);
    }

    function testFuzz_Combine(Init memory init, Token token, uint256 principal, FeePcts newFeePcts)
        public
        boundInit(init)
    {
        setUpVault(init);

        token = boundToken(token);
        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);

        _test_Combine(init, token, principal);
    }

    /// @notice Test `combine` function
    function _test_Combine(Init memory init, Token token, uint256 principal) internal {
        address caller = init.user[0];
        address receiver = init.user[1];

        uint256 oldTokenBalance = token.isNative() ? receiver.balance : token.erc20().balanceOf(receiver);

        uint256 ytBalance = yt.balanceOf(caller);
        uint256 ptBalance = principalToken.balanceOf(caller);

        principal = bound(principal, 0, FixedPointMathLib.min(ptBalance, ytBalance));

        _approve(principalToken, caller, address(zap), principal);
        _approve(yt, caller, address(zap), principal);

        vm.prank(caller);
        uint256 amountOut = zap.combine(principalToken, token, principal, receiver, 0);

        uint256 newTokenBalance = token.isNative() ? receiver.balance : token.erc20().balanceOf(receiver);

        assertEq(yt.balanceOf(caller) + principal, ytBalance, "YT mismatch");
        assertEq(principalToken.balanceOf(caller) + principal, ptBalance, "PT mismatch");
        assertEq(newTokenBalance, oldTokenBalance + amountOut, "amountOut mismatch");
        assertNoFundLeft();
    }

    function test_RevertWhen_BadPrincipalToken() public {
        vm.expectRevert(Errors.Zap_BadPrincipalToken.selector);
        zap.combine(PrincipalToken(makeAddr("badPrincipalToken")), address(target).intoToken(), 10000, alice, 0);
    }

    function test_RevertWhen_InsufficientPTAllowance() public {
        address caller = alice;
        uint256 principal = 10000;

        deal(address(principalToken), caller, principal);
        deal(address(yt), caller, principal);

        // Only approve YT, not PT
        _approve(address(yt), caller, address(zap), principal);

        vm.expectRevert();
        vm.prank(caller);
        zap.combine(principalToken, address(target).intoToken(), principal, alice, 0);
    }

    function test_RevertWhen_InsufficientYTAllowance() public {
        address caller = alice;
        uint256 principal = 10000;

        deal(address(principalToken), caller, principal);
        deal(address(yt), caller, principal);

        // Only approve PT, not YT
        _approve(address(principalToken), caller, address(zap), principal);

        vm.expectRevert();
        vm.prank(caller);
        zap.combine(principalToken, address(target).intoToken(), principal, alice, 0);
    }

    function test_RevertWhen_InsufficientPTBalance() public {
        address caller = alice;
        uint256 principal = 10000;

        // Only give YT, not PT
        deal(address(yt), caller, principal);

        _approve(principalToken, caller, address(zap), principal);
        _approve(yt, caller, address(zap), principal);

        vm.expectRevert();
        vm.prank(caller);
        zap.combine(principalToken, address(target).intoToken(), principal, alice, 0);
    }

    function test_RevertWhen_InsufficientYTBalance() public {
        address caller = alice;
        uint256 principal = 10000;

        // Only give PT, not YT
        deal(address(principalToken), caller, principal);

        _approve(principalToken, caller, address(zap), principal);
        _approve(yt, caller, address(zap), principal);

        vm.expectRevert();
        vm.prank(caller);
        zap.combine(principalToken, address(target).intoToken(), principal, alice, 0);
    }

    function test_RevertWhen_BadToken() public {
        Init memory init = toyInit();
        setUpVault(init);
        address caller = init.user[0];

        _approve(principalToken, caller, address(zap), type(uint256).max);
        _approve(yt, caller, address(zap), type(uint256).max);

        vm.prank(caller);
        vm.expectRevert(Errors.ERC4626Connector_InvalidToken.selector);
        zap.combine(principalToken, address(0xcafe).intoToken(), 1000, caller, 0);
    }

    function test_RevertWhen_InsufficientTokenOutput() public {
        Init memory init = toyInit();
        setUpVault(init);

        address caller = init.user[0];
        uint256 principal = principalToken.balanceOf(caller);

        _approve(principalToken, caller, address(zap), principal);
        _approve(yt, caller, address(zap), principal);

        vm.expectRevert(Errors.Zap_InsufficientTokenOutput.selector);
        vm.prank(caller);
        zap.combine(principalToken, address(target).intoToken(), principal, alice, type(uint256).max);
    }
}

contract ZapCombineETHTest is ZapCombineTest {
    function _deployTokens() internal override {
        _deployWETHVault();
    }

    function validTokenInput() internal view override returns (address[] memory tokens) {
        tokens = new address[](3);
        tokens[0] = address(target);
        tokens[1] = address(base);
        tokens[2] = NATIVE_ETH;
    }

    function test_CombineToNativeETH() public {
        Init memory init = toyInit();
        Token token = Token.wrap(NATIVE_ETH);
        uint256 principal = 10 ** principalToken.decimals();

        _test_Combine(init, token, principal);
    }
}
