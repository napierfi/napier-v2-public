// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";

import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {Errors} from "src/Errors.sol";
import {Token} from "src/Types.sol";
import "src/types/Token.sol" as TokenType;

using {TokenType.intoToken} for address;

contract VaultPreviewRedeemTest is TwoCryptoZapAMMTest {
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

    function test_PreviewRedeemUnderlying() public view {
        Token token = address(target).intoToken();
        uint256 shares = 10 * 10 ** target.decimals();

        uint256 a = quoter.vaultPreviewRedeem(principalToken, token, shares);
        assertEq(a, shares);
    }

    function test_PreviewRedeemBaseAsset() public view {
        Token token = address(base).intoToken();
        uint256 shares = 1212113133121;

        uint256 a = quoter.vaultPreviewRedeem(principalToken, token, shares);
        assertEq(a, target.previewRedeem(shares));
    }

    function test_RevertWhen_InvalidToken() public {
        Token token = NATIVE_ETH.intoToken();
        uint256 shares = 34933310391039341;

        vm.expectRevert(Errors.Quoter_ConnectorInvalidToken.selector);
        quoter.vaultPreviewRedeem(principalToken, token, shares);
    }

    function test_RevertWhen_BadPrincipalToken() public {
        vm.expectRevert(Errors.Zap_BadPrincipalToken.selector);
        quoter.vaultPreviewRedeem(PrincipalToken(address(0xfffff)), address(base).intoToken(), 1 ether);
    }

    function test_RevertWhen_FallbackCallFailed() public {
        vm.mockCallRevert(address(target), abi.encodeWithSelector(target.previewRedeem.selector), abi.encode("Error"));

        vm.expectRevert(Errors.Quoter_ERC4626FallbackCallFailed.selector);
        quoter.vaultPreviewRedeem(principalToken, address(base).intoToken(), 100000);
    }
}

contract VaultPreviewRedeemETHTest is TwoCryptoZapAMMTest {
    function _deployTokens() internal override {
        _deployWETHVault();

        setUpYield(int256(target.totalAssets() / 3));
    }

    function test_PreviewRedeemETH() public view {
        Token token = NATIVE_ETH.intoToken();
        uint256 shares = 3310391039341;

        uint256 assets = quoter.vaultPreviewRedeem(principalToken, token, shares);
        assertEq(assets, target.previewRedeem(shares));
    }
}
