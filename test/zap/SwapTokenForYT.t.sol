// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {ApproxValue} from "src/Types.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {LibTwoCryptoNG} from "src/utils/LibTwoCryptoNG.sol";

import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";

import "src/Constants.sol";
import {Errors} from "src/Errors.sol";
import {Token} from "src/Types.sol";
import "src/types/Token.sol" as TokenType;

using {TokenType.intoToken} for address;

contract SwapTokenForYtTest is TwoCryptoZapAMMTest {
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
    }

    function test_SwapUnderlying() public {
        setUpYield(int256(target.totalAssets() / 11));

        Token token = address(target).intoToken();
        uint256 sharesIn = 10 * 10 ** target.decimals();

        deal(token, alice, sharesIn);

        FeePcts newFeePcts = FeePctsLib.pack(3000, 100, 10, 100, 100);
        setFeePcts(newFeePcts);

        _test_Swap(alice, bob, token, sharesIn);
    }

    function testFuzz_SwapUnderlying(SetupAMMFuzzInput memory input, uint256 sharesIn, FeePcts feePcts)
        public
        boundSetupAMMFuzzInput(input)
        fuzzAMMState(input)
    {
        Token token = address(target).intoToken();
        sharesIn = bound(sharesIn, 10_000, 1e25);
        deal(token, alice, sharesIn);

        FeePcts newFeePcts = boundFeePcts(feePcts);
        setFeePcts(newFeePcts);

        (, ApproxValue sharesFlashBorrow) = _test_Swap(alice, bob, token, sharesIn);

        // - The predicted shares to flash borrow should be good approximation (Refund should be small enough)
        Vm.Log memory log = getLatestLogByTopic0(address(target), keccak256("Transfer(address,address,uint256)")); // Catch the refund transfer
        (uint256 refund) = abi.decode(log.data, (uint256));
        assertEq(address(uint160(uint256(log.topics[2]))), alice, "refund to caller");
        assertLe(refund, sharesFlashBorrow.unwrap() * 1 / 100, "refund too large");
    }

    function test_SwapBaseAsset() public {
        setUpYield(int256(target.totalAssets() / 11));

        Token token = address(base).intoToken();
        uint256 assetsIn = 10 * bOne;

        deal(token, alice, assetsIn);

        FeePcts newFeePcts = FeePctsLib.pack(3000, 55, 200, 100, 100);
        setFeePcts(newFeePcts);

        _test_Swap(alice, bob, token, assetsIn);
    }

    function testFuzz_Swap(SetupAMMFuzzInput memory input, Token token, uint256 amountIn, FeePcts newFeePcts)
        public
        boundSetupAMMFuzzInput(input)
        fuzzAMMState(input)
    {
        token = boundToken(token);
        amountIn = bound(amountIn, 0, type(uint88).max);

        address caller = alice;
        if (token.isNotNative()) deal(token, caller, amountIn);
        else deal(caller, amountIn); // Native ETH

        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);

        _test_Swap(caller, bob, token, amountIn);
    }

    function _test_Swap(address caller, address receiver, Token token, uint256 amount)
        internal
        returns (uint256 ytOut, ApproxValue sharesFlashBorrow)
    {
        uint256 oldYtBalnce = yt.balanceOf(receiver);

        if (token.isNative()) {
            amount = bound(amount, 0, caller.balance);
        } else {
            amount = bound(amount, 0, SafeTransferLib.balanceOf(token.unwrap(), caller));
            _approve(token, caller, address(zap), amount);
        }
        // Note need to consider the rounding error in the quote.
        uint256 quoterInputAmount = amount * (10_000 - 10) / (10_000);

        uint256 guessYt;
        {
            (bool s1, bytes memory ret1) = address(quoter).staticcall(
                abi.encodeCall(quoter.previewSwapTokenForYt, (twocrypto, token, quoterInputAmount))
            );
            vm.assume(s1);
            (guessYt, sharesFlashBorrow,) = abi.decode(ret1, (uint256, ApproxValue, uint256));
            vm.assume(sharesFlashBorrow.unwrap() > 10);
        }

        TwoCryptoZap.SwapTokenParams memory params = TwoCryptoZap.SwapTokenParams({
            twoCrypto: twocrypto,
            tokenIn: token,
            amountIn: amount,
            receiver: receiver,
            minPrincipal: 0,
            deadline: block.timestamp
        });

        vm.recordLogs();
        {
            vm.prank(caller);
            (bool s, bytes memory ret) = address(zap).call{value: token.isNative() ? amount : 0}(
                abi.encodeCall(zap.swapTokenForYt, (params, sharesFlashBorrow))
            );
            // Note Even if the quote succeeded, the swap can fail in `twoCrypto::tweak_price` internal function. https://github.com/curvefi/twocrypto-ng/blob/369aade39b54492f013a8ebf3390075f6ea84090/contracts/main/CurveTwocryptoOptimized.vy#L921
            assertTrue(
                s || bytes4(ret) == LibTwoCryptoNG.TwoCryptoNG_ExchangeReceivedFailed.selector,
                "Quote succeeded but swap failed"
            );
            if (!s) {
                assertTrue(
                    bytes4(ret) != Errors.Zap_DebtExceedsUnderlyingReceived.selector,
                    "DebtExceedsUnderlyingReceived error should not be thrown"
                );
            }
            vm.assume(s);
            ytOut = abi.decode(ret, (uint256));
        }

        // Zap asserts
        assertNoFundLeft();
        assertEq(yt.balanceOf(params.receiver) - oldYtBalnce, ytOut, "yt balance");

        // Quoter asserts
        // - Minted YT should be approximately equal to the predicted amount
        assertApproxEqAbs(ytOut, guessYt, 100000, "ytOut vs guessYt");
    }

    function test_RevertWhen_BadToken() public {
        TwoCryptoZap.SwapTokenParams memory params = toyParams();
        params.tokenIn = address(randomToken).intoToken();
        deal(params.tokenIn, address(this), params.amountIn);
        _approve(params.tokenIn, address(this), address(zap), params.amountIn);

        vm.expectRevert(Errors.ERC4626Connector_InvalidToken.selector);
        zap.swapTokenForYt(params, ApproxValue.wrap(11212));
    }

    function test_RevertWhen_SlippageTooLarge() public {
        TwoCryptoZap.SwapTokenParams memory params = toyParams();
        params.tokenIn = address(base).intoToken();

        deal(params.tokenIn, alice, params.amountIn);
        _approve(params.tokenIn, alice, address(zap), type(uint256).max);

        (, ApproxValue sharesFlashBorrow,) = quoter.previewSwapTokenForYt(twocrypto, params.tokenIn, params.amountIn);

        params.minPrincipal = 1e24;
        vm.expectRevert(Errors.Zap_InsufficientYieldTokenOutput.selector);
        vm.prank(alice);
        zap.swapTokenForYt(params, sharesFlashBorrow);
    }

    function test_RevertWhen_TransactionTooOld() public {
        TwoCryptoZap.SwapTokenParams memory params = toyParams();
        params.deadline = block.timestamp - 1;

        vm.expectRevert(Errors.Zap_TransactionTooOld.selector);
        zap.swapTokenForYt(params, ApproxValue.wrap(11212));
    }

    function test_RevertWhen_DebtExceedsUnderlyingReceived() public {
        vm.skip(true);
    }

    function toyParams() internal view returns (TwoCryptoZap.SwapTokenParams memory) {
        return TwoCryptoZap.SwapTokenParams({
            twoCrypto: twocrypto,
            tokenIn: address(base).intoToken(),
            amountIn: bOne,
            receiver: alice,
            minPrincipal: 0,
            deadline: block.timestamp
        });
    }
}

contract SwapETHForYtTestTest is SwapTokenForYtTest {
    function _deployTokens() internal override {
        _deployWETHVault();
    }

    function validTokenInput() internal view override returns (address[] memory tokens) {
        tokens = new address[](3);
        tokens[0] = address(target);
        tokens[1] = address(base);
        tokens[2] = NATIVE_ETH;
    }

    function test_SwapNativeETH() public {
        setUpYield(int256(target.totalAssets() / 11));

        Token token = NATIVE_ETH.intoToken();
        uint256 value = 10 ether;

        vm.deal(alice, value);

        _test_Swap(alice, bob, token, value);
    }

    function test_RevertWhen_InsufficientETH() public {
        TwoCryptoZap.SwapTokenParams memory params = toyParams();
        params.tokenIn = NATIVE_ETH.intoToken();
        params.amountIn = 100;

        vm.expectRevert(Errors.Zap_InsufficientETH.selector);
        zap.swapTokenForYt{value: 99}(params, ApproxValue.wrap(11212));
    }
}
