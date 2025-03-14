// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";

import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {Errors} from "src/Errors.sol";
import {Token} from "src/Types.sol";
import "src/types/Token.sol" as TokenType;

using {TokenType.intoToken} for address;

contract PreviewRedeemTest is TwoCryptoZapAMMTest {
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

    function test_PreviewRedeemUnderlying(uint64 timeJump) public {
        Token token = address(target).intoToken();
        uint256 sharesIn = 10 * 10 ** target.decimals();

        skip(timeJump);

        uint256 s = quoter.previewRedeem(principalToken, token, sharesIn);
        assertEq(s, principalToken.previewRedeem(sharesIn));
    }

    function test_PreviewRedeemBaseAsset(uint64 timeJump) public {
        Token token = address(base).intoToken();
        uint256 principal = 1212113133121;

        skip(timeJump);

        uint256 assets = quoter.previewRedeem(principalToken, token, principal);
        assertEq(assets, target.previewRedeem(principalToken.previewRedeem(principal)));
    }

    function test_RevertWhen_InvalidToken() public {
        Token token = NATIVE_ETH.intoToken();
        uint256 principal = 34933310391039341;

        vm.expectRevert(Errors.Quoter_ConnectorInvalidToken.selector);
        quoter.previewRedeem(principalToken, token, principal);
    }

    function test_RevertWhen_BadPrincipalToken() public {
        vm.expectRevert(Errors.Zap_BadPrincipalToken.selector);
        quoter.previewRedeem(PrincipalToken(address(0xfffff)), address(base).intoToken(), 1 ether);
    }

    function test_RevertWhen_FallbackCallFailed() public {
        vm.mockCallRevert(address(target), abi.encodeWithSelector(target.previewRedeem.selector), abi.encode("Error"));

        vm.expectRevert(Errors.Quoter_ERC4626FallbackCallFailed.selector);
        quoter.previewRedeem(principalToken, address(base).intoToken(), 100000);
    }
}

contract PreviewRedeemETHTest is TwoCryptoZapAMMTest {
    function _deployTokens() internal override {
        _deployWETHVault();
    }

    function test_PreviewRedeemETH() public view {
        Token token = NATIVE_ETH.intoToken();
        uint256 principal = 34039341;

        uint256 s = quoter.previewRedeem(principalToken, token, principal);
        assertEq(s, target.previewRedeem(principalToken.previewRedeem(principal)));
    }
}
