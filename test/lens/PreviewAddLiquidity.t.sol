// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";
import {ITwoCrypto} from "../shared/ITwoCrypto.sol";

import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {Errors} from "src/Errors.sol";
import {Token, TwoCrypto} from "src/Types.sol";
import "src/types/Token.sol" as TokenType;

using {TokenType.intoToken} for address;

contract PreviewAddLiquidityTest is TwoCryptoZapAMMTest {
    function setUp() public override {
        super.setUp();
        _label();

        uint256 initialPrincipal = 140_000 * tOne;
        uint256 initialShare = 100_000 * tOne;

        // Setup initial AMM liquidity
        setUpAMM(AMMInit({user: makeAddr("bocchi"), share: initialShare, principal: initialPrincipal}));
        setUpYield(int256(target.totalAssets() / 3));
    }

    function testFuzz_PreviewAddLiquidity(uint56 timeJump, uint256[2] memory amounts) public {
        skip(timeJump);
        try ITwoCrypto(twocrypto.unwrap()).calc_token_amount(amounts, true) returns (uint256 liquidity) {
            assertEq(quoter.previewAddLiquidity(twocrypto, amounts[0], amounts[1]), liquidity, "Liquidity");
        } catch {}
    }

    function test_RevertWhen_BadTwoCrypto() public {
        vm.expectRevert(Errors.Zap_BadTwoCrypto.selector);
        quoter.previewAddLiquidity(TwoCrypto.wrap(address(0xfffff)), 1212, 2110921029);
    }
}

contract PreviewAddLiquidityOneTokenTest is TwoCryptoZapAMMTest {
    function setUp() public override {
        super.setUp();
        _label();

        uint256 initialPrincipal = 140_000 * tOne;
        uint256 initialShare = 100_000 * tOne;

        // Setup initial AMM liquidity
        setUpAMM(AMMInit({user: makeAddr("bocchi"), share: initialShare, principal: initialPrincipal}));
        setUpYield(int256(target.totalAssets() / 3));
    }

    function test_PreviewAddLiquidityUnderlying() public {
        Token token = address(target).intoToken();
        uint256 shares = 353258901219909923;
        uint256 timeJump = 10 days;
        _test_Preview(timeJump, token, shares);
    }

    function test_PreviewAddLiquidityBaseAsset() public {
        Token token = address(base).intoToken();
        uint256 assets = 3599002090994393;
        uint256 timeJump = 10 days;

        _test_Preview(timeJump, token, assets);
    }

    function test_WhenExpired() public {
        Token token = address(base).intoToken();
        uint256 assets = 359009949393;
        uint256 timeJump = 100 * 365 days;

        _test_Preview(timeJump, token, assets);
    }

    function _test_Preview(uint256 timeJump, Token tokenIn, uint256 amountIn) internal {
        skip(timeJump);

        (uint256 l, uint256 p) = quoter.previewAddLiquidityOneToken(twocrypto, tokenIn, amountIn);
        if (isExpired()) {
            assertEq(l, 0, "Liquidity should be 0 when expired");
            assertEq(p, 0, "Principal should be 0 when expired");
            return;
        }

        deal(tokenIn, alice, amountIn);
        if (tokenIn.isNotNative()) _approve(tokenIn, alice, address(zap), amountIn);

        TwoCryptoZap.AddLiquidityOneTokenParams memory params = TwoCryptoZap.AddLiquidityOneTokenParams({
            twoCrypto: twocrypto,
            tokenIn: tokenIn,
            amountIn: amountIn,
            receiver: alice,
            minLiquidity: 0,
            minYt: 0,
            deadline: block.timestamp
        });

        vm.prank(alice);
        (uint256 actualLiquidity, uint256 actualPrincipal) =
            zap.addLiquidityOneToken{value: tokenIn.isNative() ? amountIn : 0}(params);

        assertEq(l, actualLiquidity, "Liquidity");
        assertEq(p, actualPrincipal, "Principal");
    }

    function test_RevertWhen_InvalidToken() public virtual {
        Token token = NATIVE_ETH.intoToken();
        uint256 value = 34933310391039341;

        vm.expectRevert(Errors.Quoter_ConnectorInvalidToken.selector);
        quoter.previewAddLiquidityOneToken(twocrypto, token, value);
    }

    function test_RevertWhen_BadTwoCrypto() public {
        vm.expectRevert(Errors.Zap_BadTwoCrypto.selector);
        quoter.previewAddLiquidityOneToken(TwoCrypto.wrap(address(0xfffff)), address(base).intoToken(), 2103913);
    }

    function test_RevertWhen_FallbackCallFailed() public {
        vm.mockCallRevert(address(target), abi.encodeWithSelector(target.previewDeposit.selector), abi.encode("Error"));

        vm.expectRevert(Errors.Quoter_ERC4626FallbackCallFailed.selector);
        quoter.previewAddLiquidityOneToken(twocrypto, address(base).intoToken(), 100000);
    }
}

contract PreviewAddLiquidityOneETHTest is PreviewAddLiquidityOneTokenTest {
    function _deployTokens() internal override {
        _deployWETHVault();
    }

    function test_PreviewAddLiquidityETH() public {
        Token token = NATIVE_ETH.intoToken();
        uint256 value = 1 ether;
        uint256 timeJump = 1 days;
        _test_Preview(timeJump, token, value);
    }

    function test_RevertWhen_InvalidToken() public override {
        Token token = address(0xffff).intoToken();
        uint256 asset = 34933310391039341;

        vm.expectRevert(Errors.Quoter_ConnectorInvalidToken.selector);
        quoter.previewAddLiquidityOneToken(twocrypto, token, asset);
    }
}
