// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";

import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";

import {LibTwoCryptoNG} from "src/utils/LibTwoCryptoNG.sol";
import {Token, TwoCrypto} from "src/Types.sol";
import "src/types/Token.sol" as TokenType;
import {Errors} from "src/Errors.sol";

using {TokenType.intoToken} for address;

contract PreviewRemoveLiquidityTest is TwoCryptoZapAMMTest {
    using LibTwoCryptoNG for TwoCrypto;

    function setUp() public override {
        super.setUp();
        _label();

        uint256 initialPrincipal = 140_000 * tOne;
        uint256 initialShare = 100_000 * tOne;

        // Setup initial AMM liquidity
        setUpAMM(AMMInit({user: makeAddr("bocchi"), share: initialShare, principal: initialPrincipal}));
    }

    function test_PreviewRemoveLiquidity() public {
        uint256 liquidity = 353258901219909923;
        SetupAMMFuzzInput memory input;
        testFuzz_Preview(input, liquidity);
    }

    function testFuzz_Preview(SetupAMMFuzzInput memory input, uint256 liquidity)
        public
        boundSetupAMMFuzzInput(input)
        fuzzAMMState(input)
    {
        liquidity = bound(liquidity, 0, twocrypto.totalSupply());
        deal(twocrypto.unwrap(), alice, liquidity);

        _approve(twocrypto.unwrap(), alice, address(zap), liquidity);
        (uint256 shares, uint256 principal) = quoter.previewRemoveLiquidity(twocrypto, liquidity);

        vm.prank(alice);
        TwoCryptoZap.RemoveLiquidityParams memory params = TwoCryptoZap.RemoveLiquidityParams({
            twoCrypto: twocrypto,
            liquidity: liquidity,
            receiver: alice,
            minShares: 0,
            minPrincipal: 0,
            deadline: block.timestamp
        });
        (bool s, bytes memory ret) = address(zap).call(abi.encodeCall(zap.removeLiquidity, (params)));

        vm.assume(s);
        (uint256 actualShares, uint256 actualPrincipal) = abi.decode(ret, (uint256, uint256));
        assertEq(shares, actualShares, "Shares");
        assertEq(principal, actualPrincipal, "Principal");
    }

    function test_RevertWhen_BadTwoCrypto() public {
        vm.expectRevert(Errors.Zap_BadTwoCrypto.selector);
        quoter.previewRemoveLiquidity(TwoCrypto.wrap(address(0xfffff)), 100000);
    }
}

contract PreviewRemoveLiquidityOneTokenTest is TwoCryptoZapAMMTest {
    using LibTwoCryptoNG for TwoCrypto;

    function setUp() public override {
        super.setUp();
        _label();

        uint256 initialPrincipal = 140_000 * tOne;
        uint256 initialShare = 100_000 * tOne;

        // Setup initial AMM liquidity
        setUpAMM(AMMInit({user: makeAddr("bocchi"), share: initialShare, principal: initialPrincipal}));
        setUpYield(int256(target.totalAssets() / 3));
    }

    function test_Preview_Underlying() public {
        Token token = address(target).intoToken();
        uint256 liquidity = 353258901219909923;
        uint256 timeJump = 10 days;

        _test_Preview(timeJump, token, liquidity);
    }

    function test_Preview_BaseAsset() public {
        Token token = address(base).intoToken();
        uint256 liquidity = 3599002090994393;
        uint256 timeJump = 10 days;

        _test_Preview(timeJump, token, liquidity);
    }

    function test_Preview_BaseAssetWhenExpired() public {
        Token token = address(base).intoToken();
        uint256 liquidity = 359009949393;
        uint256 timeJump = 100 * 365 days;

        _test_Preview(timeJump, token, liquidity);
    }

    function test_Preview_UnderlyingWhenExpired() public {
        Token token = address(target).intoToken();
        uint256 liquidity = 359009949393;
        uint256 timeJump = 100 * 365 days;

        _test_Preview(timeJump, token, liquidity);
    }

    function _test_Preview(uint256 timeJump, Token tokenOut, uint256 liquidity) internal {
        skip(timeJump);

        liquidity = bound(liquidity, 0, twocrypto.totalSupply());
        deal(twocrypto.unwrap(), alice, liquidity);

        if (isExpired()) {
            vm.expectCall(address(principalToken), abi.encodeWithSelector(principalToken.previewRedeem.selector));
        }
        uint256 amountOut = quoter.previewRemoveLiquidityOneToken(twocrypto, tokenOut, liquidity);

        TwoCryptoZap.RemoveLiquidityOneTokenParams memory params = TwoCryptoZap.RemoveLiquidityOneTokenParams({
            twoCrypto: twocrypto,
            tokenOut: tokenOut,
            liquidity: liquidity,
            receiver: alice,
            amountOutMin: 0,
            deadline: block.timestamp
        });

        _approve(twocrypto.unwrap(), alice, address(zap), liquidity);
        vm.prank(alice);
        uint256 actual = zap.removeLiquidityOneToken(params);

        assertApproxEqAbs(actual, amountOut, 5, "amountOut");
    }

    function test_RevertWhen_InvalidToken() public virtual {
        Token token = NATIVE_ETH.intoToken();
        uint256 value = 34933310391039341;

        vm.expectRevert(Errors.Quoter_ConnectorInvalidToken.selector);
        quoter.previewRemoveLiquidityOneToken(twocrypto, token, value);
    }

    function test_RevertWhen_BadTwoCrypto() public {
        vm.expectRevert(Errors.Zap_BadTwoCrypto.selector);
        quoter.previewRemoveLiquidityOneToken(TwoCrypto.wrap(address(0xfffff)), address(base).intoToken(), 2103913);
    }

    function test_RevertWhen_FallbackCallFailed() public {
        vm.mockCallRevert(address(target), abi.encodeWithSelector(target.previewRedeem.selector), abi.encode("Error"));

        vm.expectRevert(Errors.Quoter_ERC4626FallbackCallFailed.selector);
        quoter.previewRemoveLiquidityOneToken(twocrypto, address(base).intoToken(), 100000);
    }
}

contract PreviewRemoveLiquidityOneETHTest is PreviewRemoveLiquidityOneTokenTest {
    function _deployTokens() internal override {
        _deployWETHVault();
    }

    function test_PreviewRemoveLiquidityETH() public {
        Token token = NATIVE_ETH.intoToken();
        uint256 value = 1 ether;
        uint256 timeJump = 1 days;
        _test_Preview(timeJump, token, value);
    }

    function test_RevertWhen_InvalidToken() public override {
        Token token = address(0xffff).intoToken();
        uint256 assets = 34933310391039341;

        vm.expectRevert(Errors.Quoter_ConnectorInvalidToken.selector);
        quoter.previewRemoveLiquidityOneToken(twocrypto, token, assets);
    }
}
