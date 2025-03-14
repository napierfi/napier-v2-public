// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";

import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {Errors} from "src/Errors.sol";
import {Token} from "src/Types.sol";
import "src/types/Token.sol" as TokenType;

using {TokenType.intoToken} for address;

contract PreviewSupplyTest is TwoCryptoZapAMMTest {
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

    function test_PreviewSupplyUnderlying(uint64 timeJump) public {
        Token token = address(target).intoToken();
        uint256 sharesIn = 10 * 10 ** target.decimals();

        skip(timeJump);

        uint256 p = quoter.previewSupply(principalToken, token, sharesIn);
        assertEq(p, principalToken.previewSupply(sharesIn));
    }

    function test_PreviewSupplyBaseAsset(uint64 timeJump) public {
        Token token = address(base).intoToken();
        uint256 assets = 131301133121;

        skip(timeJump);

        uint256 p = quoter.previewSupply(principalToken, token, assets);
        assertEq(p, target.previewDeposit(principalToken.previewSupply(assets)));
    }

    function test_RevertWhen_InvalidToken() public {
        Token token = NATIVE_ETH.intoToken();
        uint256 value = 34933310391039341;

        vm.expectRevert(Errors.Quoter_ConnectorInvalidToken.selector);
        quoter.previewSupply(principalToken, token, value);
    }

    function test_RevertWhen_BadPrincipalToken() public {
        vm.expectRevert(Errors.Zap_BadPrincipalToken.selector);
        quoter.previewSupply(PrincipalToken(address(0xfffff)), address(base).intoToken(), 1 ether);
    }

    function test_RevertWhen_FallbackCallFailed() public {
        vm.mockCallRevert(address(target), abi.encodeWithSelector(target.previewDeposit.selector), abi.encode("Error"));

        vm.expectRevert(Errors.Quoter_ERC4626FallbackCallFailed.selector);
        quoter.previewSupply(principalToken, address(base).intoToken(), 100000);
    }
}

contract PreviewSupplyETHTest is TwoCryptoZapAMMTest {
    function _deployTokens() internal override {
        _deployWETHVault();
    }

    function test_PreviewSupplyETH() public view {
        Token token = NATIVE_ETH.intoToken();
        uint256 value = 34039341;

        uint256 p = quoter.previewSupply(principalToken, token, value);
        assertEq(p, principalToken.previewSupply(target.previewDeposit(value)));
    }
}
