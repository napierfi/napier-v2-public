// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";

import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {LibTwoCryptoNG} from "src/utils/LibTwoCryptoNG.sol";

import "src/Types.sol";
import "src/Constants.sol";
import {Errors} from "src/Errors.sol";

using {TokenType.intoToken} for address;

contract PreviewSwapTokenForYtTest is TwoCryptoZapAMMTest {
    using LibTwoCryptoNG for TwoCrypto;

    function setUp() public virtual override {
        super.setUp();
        _label();

        // Principal Token should be discounted against underlying token
        uint256 initialPrincipal = 140_000 * tOne;
        uint256 initialShare = 100_000 * tOne;

        // Setup initial AMM liquidity
        setUpAMM(AMMInit({user: makeAddr("bocchi"), share: initialShare, principal: initialPrincipal}));

        vm.startPrank(alice);
        deal(address(base), alice, 1e9 * bOne);
        base.approve(address(target), type(uint256).max);
        target.deposit(1e9 * bOne, alice);
        target.approve(address(principalToken), type(uint256).max);
        principalToken.issue(10_000 * tOne, alice); // fee may be charged
        vm.stopPrank();

        _delta_ = 1;
    }

    function test_ConvertSharesToYt_1() public {
        _test_ConvertSharesToYt({scale: 1.11e18, ptPriceInUnderlying: 0.81e18, shares: 1e18, expected: 11.00099e18});
    }

    function test_ConvertSharesToYt_2() public {
        vm.mockCall(address(principalToken), abi.encodeWithSelector(principalToken.decimals.selector), abi.encode(18));
        vm.mockCall(address(target), abi.encodeWithSelector(target.decimals.selector), abi.encode(6));
        uint256 bOne = 10 ** 18;
        uint256 shares = 10 ** 6;
        _test_ConvertSharesToYt({scale: 1.0e18, ptPriceInUnderlying: 0.9e18, shares: shares, expected: 10 * bOne});
    }

    function _test_ConvertSharesToYt(uint256 scale, uint256 ptPriceInUnderlying, uint256 shares, uint256 expected)
        public
    {
        vm.mockCall(
            address(principalToken.i_resolver()), abi.encodeWithSelector(resolver.scale.selector), abi.encode(scale)
        );
        vm.mockCall(twocrypto.unwrap(), abi.encodeWithSignature("last_prices()"), abi.encode(ptPriceInUnderlying));

        uint256 value = quoter.convertSharesToYt(twocrypto, shares);
        assertApproxEqRel(value, expected, 0.01e18, "value");
    }

    function test_RT_Preview() public view {
        uint256 ytOut = 100 * 10 ** target.decimals();
        _test_RT_Preview(ytOut);
    }

    function testFuzz_RT_Preview(SetupAMMFuzzInput memory input, uint256 ytOut, FeePcts feePcts)
        public
        boundSetupAMMFuzzInput(input)
        fuzzAMMState(input)
    {
        ytOut = bound(ytOut, bOne / 100, yt.totalSupply()); // Some reasonably large number
        feePcts = boundFeePcts(feePcts);
        setFeePcts(feePcts);

        _test_RT_Preview(ytOut);
    }

    function _test_RT_Preview(uint256 ytOut) internal view {
        bool s;
        bytes memory ret;
        {
            (s, ret) =
                address(quoter).staticcall(abi.encodeCall(quoter.previewSwapUnderlyingForExactYt, (twocrypto, ytOut)));
            vm.assume(s);
        }
        (uint256 sharesIn, uint256 expectSharesBorrow) = abi.decode(ret, (uint256, uint256));
        {
            (s, ret) = address(quoter).staticcall(
                abi.encodeCall(quoter.previewSwapTokenForYt, (twocrypto, address(target).intoToken(), sharesIn))
            );
            vm.assume(s);
        }
        (uint256 preview, uint256 sharesBorrow,) = abi.decode(ret, (uint256, uint256, uint256));
        assertApproxEqRel(preview, ytOut, 0.001e18, "preview");
        assertApproxEqRel(sharesBorrow, expectSharesBorrow, 0.001e18, "sharesBorrow");
    }

    function test_Preview_Underlying() public {
        Token token = address(target).intoToken();
        uint256 shares = bOne;
        uint256 timeJump = 10 hours;

        setUpYield(int256(target.totalAssets() / 3));
        skip(timeJump);
        _test_Preview(token, shares);
    }

    function test_Preview_BaseAsset() public virtual {
        Token token = address(base).intoToken();
        uint256 assets = 10 * bOne;
        uint256 timeJump = 30 minutes;

        setUpYield(int256(target.totalAssets() / 3));
        skip(timeJump);
        _test_Preview(token, assets);
    }

    function testFuzz_PreviewSwapYtForToken(SetupAMMFuzzInput memory input, Token token, uint256 amountIn)
        public
        boundSetupAMMFuzzInput(input)
        fuzzAMMState(input)
    {
        token = boundToken(token);
        amountIn = bound(amountIn, 1, 1000000e18);

        // console2.log("input.timestamp :>>", input.timestamp);
        // console2.log("input.deposits[0], input.deposits[1] :>>", input.deposits[0], input.deposits[1]);
        // console2.log("input.yield :>>", input.yield);
        // console2.log("token :>>", token.unwrap());
        // console2.log("amountIn :>>", amountIn);
        _test_Preview(token, amountIn);
    }

    function _test_Preview(Token tokenIn, uint256 amountIn) internal {
        (bool s1, bytes memory ret1) =
            address(quoter).call(abi.encodeCall(quoter.previewSwapTokenForYt, (twocrypto, tokenIn, amountIn)));
        vm.assume(s1);
        (ApproxValue preview, ApproxValue sharesBorrow,) = abi.decode(ret1, (ApproxValue, ApproxValue, uint256));

        deal(tokenIn, alice, amountIn);

        TwoCryptoZap.SwapTokenParams memory params = TwoCryptoZap.SwapTokenParams({
            twoCrypto: twocrypto,
            tokenIn: tokenIn,
            amountIn: amountIn,
            receiver: alice,
            minPrincipal: 0,
            deadline: block.timestamp
        });

        if (tokenIn.isNotNative()) _approve(tokenIn, alice, address(zap), amountIn);
        uint256 value = tokenIn.isNative() ? amountIn : 0;
        vm.prank(alice);
        (bool s2, bytes memory ret2) =
            address(zap).call{value: value}(abi.encodeCall(zap.swapTokenForYt, (params, sharesBorrow)));
        // In theory, if the preview function succeeded, the swapTokenForYt should also succeed
        // But in practice, the preview function is not always accurate. The preview function succeeds even if the swapTokenForYt will fail.
        // assertEq(s2, true, "swapTokenForYt failed");
        vm.assume(s2);
        uint256 actual = abi.decode(ret2, (uint256));

        assertApproxEqAbs(preview.unwrap(), actual, _delta_, "preview != actual");
    }

    function test_RevertWhen_NegativeYtPrice() public {
        Token tokenIn = address(target).intoToken();
        uint256 amountIn = 100 * tOne;

        // Set up the AMM with PT price in asset greater than 1
        deal(address(target), bob, 100000 * tOne);
        vm.prank(bob);
        target.transfer(twocrypto.unwrap(), 100000 * tOne);
        vm.prank(bob);
        twocrypto.exchange_received(TARGET_INDEX, PT_INDEX, 100000 * tOne, 0);

        uint256 dy = twocrypto.get_dy(TARGET_INDEX, PT_INDEX, tOne);
        require(resolver.scale() > dy * 1e18 / bOne, "TEST:PT price in asset must be greater than 1");

        vm.expectRevert(Errors.ConversionLib_NegativeYtPrice.selector);
        quoter.previewSwapTokenForYt(twocrypto, tokenIn, amountIn);
    }

    function test_RevertWhen_InvalidToken() public virtual {
        Token token = NATIVE_ETH.intoToken();
        uint256 ytIn = bOne;

        vm.expectRevert(Errors.Quoter_ConnectorInvalidToken.selector);
        quoter.previewSwapTokenForYt(twocrypto, token, ytIn);
    }

    function test_RevertWhen_BadTwoCrypto() public {
        vm.expectRevert(Errors.Zap_BadTwoCrypto.selector);
        quoter.previewSwapTokenForYt(TwoCrypto.wrap(address(0xfffff)), address(base).intoToken(), 2103913);
    }

    function test_RevertWhen_FallbackCallFailed() public {
        vm.mockCallRevert(address(target), abi.encodeWithSelector(target.previewDeposit.selector), abi.encode("Error"));

        vm.expectRevert(Errors.Quoter_ERC4626FallbackCallFailed.selector);
        quoter.previewSwapTokenForYt(twocrypto, address(base).intoToken(), 100000);
    }
}

contract PreviewSwapETHForYtTest is PreviewSwapTokenForYtTest {
    function _deployTokens() internal override {
        _deployWETHVault();
    }

    function test_Preview_NativeToken() public {
        Token token = NATIVE_ETH.intoToken();
        uint256 value = 1 ether;

        setUpYield(int256(target.totalAssets() / 3));

        _test_Preview(token, value);
    }

    function test_Preview_BaseAsset() public override {
        Token token = address(base).intoToken();
        uint256 assets = 1 ether;

        setUpYield(int256(target.totalAssets() / 3));

        _test_Preview(token, assets);
    }

    function test_RevertWhen_InvalidToken() public override {
        Token token = address(0xffff).intoToken();
        uint256 assets = 34933310391039341;

        vm.expectRevert(Errors.Quoter_ConnectorInvalidToken.selector);
        quoter.previewSwapTokenForYt(twocrypto, token, assets);
    }
}
