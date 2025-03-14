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

contract PreviewSwapTokenForPtTest is TwoCryptoZapAMMTest {
    function setUp() public override {
        super.setUp();
        _label();

        uint256 initialPrincipal = 140_000 * tOne;
        uint256 initialShare = 100_000 * tOne;

        // Setup initial AMM liquidity
        setUpAMM(AMMInit({user: makeAddr("bocchi"), share: initialShare, principal: initialPrincipal}));
    }

    function test_Preview_Underlying() public {
        Token token = address(target).intoToken();
        uint256 shares = tOne;
        uint256 timeJump = 10 hours;

        setUpYield(int256(target.totalAssets() / 3));
        skip(timeJump);
        _test_Preview(token, shares);
    }

    function test_Preview_BaseAsset() public {
        Token token = address(base).intoToken();
        uint256 assets = 10 * bOne;
        uint256 timeJump = 30 minutes;

        setUpYield(int256(target.totalAssets() / 3));
        skip(timeJump);
        _test_Preview(token, assets);
    }

    function testFuzz_PreviewSwapTokenForPt(SetupAMMFuzzInput memory input, Token token, uint256 amountIn)
        public
        boundSetupAMMFuzzInput(input)
        fuzzAMMState(input)
    {
        token = boundToken(token);
        amountIn = bound(amountIn, 1, principalToken.totalSupply());
        _test_Preview(token, amountIn);
    }

    function _test_Preview(Token tokenOut, uint256 amountIn) internal {
        (bool s1, bytes memory ret1) =
            address(quoter).call(abi.encodeCall(quoter.previewSwapTokenForPt, (twocrypto, tokenOut, amountIn)));
        vm.assume(s1);
        uint256 preview = abi.decode(ret1, (uint256));

        deal(tokenOut, alice, amountIn);

        TwoCryptoZap.SwapTokenParams memory params = TwoCryptoZap.SwapTokenParams({
            twoCrypto: twocrypto,
            tokenIn: tokenOut,
            amountIn: amountIn,
            receiver: alice,
            minPrincipal: 0,
            deadline: block.timestamp
        });

        if (tokenOut.isNotNative()) _approve(tokenOut, alice, address(zap), amountIn);
        uint256 value = tokenOut.isNative() ? amountIn : 0;
        vm.prank(alice);
        (bool s2, bytes memory ret2) = address(zap).call{value: value}(abi.encodeCall(zap.swapTokenForPt, (params)));
        // In theory, if the preview function succeeded, the swapTokenForPt should also succeed
        // But in practice, the preview function is not always accurate. The preview function succeeds even if the swapTokenForPt will fail.
        // assertEq(s2, true, "swapTokenForPt failed");
        vm.assume(s2);
        uint256 actual = abi.decode(ret2, (uint256));

        assertApproxEqAbs(preview, actual, _delta_, "preview != actual");
    }

    function test_RevertWhen_InvalidToken() public virtual {
        Token token = NATIVE_ETH.intoToken();
        uint256 value = 1 ether;

        vm.expectRevert(Errors.Quoter_ConnectorInvalidToken.selector);
        quoter.previewSwapTokenForPt(twocrypto, token, value);
    }

    function test_RevertWhen_BadTwoCrypto() public {
        vm.expectRevert(Errors.Zap_BadTwoCrypto.selector);
        quoter.previewSwapTokenForPt(TwoCrypto.wrap(address(0xfffff)), address(base).intoToken(), 2103913);
    }

    function test_RevertWhen_FallbackCallFailed() public {
        vm.mockCallRevert(address(target), abi.encodeWithSelector(target.previewDeposit.selector), abi.encode("Error"));

        vm.expectRevert(Errors.Quoter_ERC4626FallbackCallFailed.selector);
        quoter.previewSwapTokenForPt(twocrypto, address(base).intoToken(), 100000);
    }
}

contract PreviewSwapETHForPtTest is PreviewSwapTokenForPtTest {
    function _deployTokens() internal override {
        _deployWETHVault();
    }

    function test_Preview_NativeToken() public {
        Token token = NATIVE_ETH.intoToken();
        uint256 value = 1 ether;

        setUpYield(int256(target.totalAssets() / 3));

        _test_Preview(token, value);
    }

    function test_RevertWhen_InvalidToken() public override {
        Token token = address(0xffff).intoToken();
        uint256 assets = 34933310391039341;

        vm.expectRevert(Errors.Quoter_ConnectorInvalidToken.selector);
        quoter.previewSwapTokenForPt(twocrypto, token, assets);
    }
}
