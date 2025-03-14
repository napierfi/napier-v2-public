// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";

import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {Errors} from "src/Errors.sol";
import {Token} from "src/Types.sol";
import "src/types/Token.sol" as TokenType;

using {TokenType.intoToken} for address;

contract PreviewCombineTest is TwoCryptoZapAMMTest {
    function setUp() public override {
        super.setUp();
        _label();

        Init memory init = Init({
            user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [uint256(1e18), 768143, 38934923, 31287],
            principal: [uint256(131311313), 0, 313130, 0],
            yield: 30009218913
        });
        setUpVault(init);
    }

    function test_PreviewCombineUnderlying() public view {
        Token token = address(target).intoToken();
        uint256 sharesIn = 10 * 10 ** target.decimals();

        uint256 s = quoter.previewCombine(principalToken, token, sharesIn);
        assertEq(s, principalToken.previewCombine(sharesIn));
    }

    function test_PreviewCombineBaseAsset() public view {
        Token token = address(base).intoToken();
        uint256 principal = 1212113133121;

        uint256 assets = quoter.previewCombine(principalToken, token, principal);
        assertEq(assets, target.previewRedeem(principalToken.previewCombine(principal)));
    }

    function test_RevertWhen_InvalidToken() public {
        Token token = NATIVE_ETH.intoToken();
        uint256 principal = 34933310391039341;

        vm.expectRevert(Errors.Quoter_ConnectorInvalidToken.selector);
        quoter.previewCombine(principalToken, token, principal);
    }

    function test_RevertWhen_BadPrincipalToken() public {
        vm.expectRevert(Errors.Zap_BadPrincipalToken.selector);
        quoter.previewCombine(PrincipalToken(address(0xfffff)), address(base).intoToken(), 1 ether);
    }

    function test_RevertWhen_FallbackCallFailed() public {
        vm.mockCallRevert(address(target), abi.encodeWithSelector(target.previewRedeem.selector), abi.encode("Error"));

        vm.expectRevert(Errors.Quoter_ERC4626FallbackCallFailed.selector);
        quoter.previewCombine(principalToken, address(base).intoToken(), 100000);
    }
}

contract PreviewCombineETHTest is TwoCryptoZapAMMTest {
    function _deployTokens() internal override {
        _deployWETHVault();
    }

    function test_PreviewCombineETH() public view {
        Token token = NATIVE_ETH.intoToken();
        uint256 principal = 34039341;

        uint256 s = quoter.previewCombine(principalToken, token, principal);
        assertEq(s, target.previewRedeem(principalToken.previewCombine(principal)));
    }
}
