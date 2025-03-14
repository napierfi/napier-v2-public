// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";
import {ITwoCrypto} from "../shared/ITwoCrypto.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {TwoCrypto, LibTwoCryptoNG} from "src/utils/LibTwoCryptoNG.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import "src/Types.sol";
import "src/Constants.sol" as Constants;
import {Errors} from "src/Errors.sol";

import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {TwoCryptoNGPreviewLib} from "src/utils/TwoCryptoNGPreviewLib.sol";

using {TokenType.intoToken} for address;

contract SwapYtForTokenTest is TwoCryptoZapAMMTest {
    using LibTwoCryptoNG for TwoCrypto;

    function setUp() public virtual override {
        super.setUp();
        _label();

        // Principal Token should be discounted against underlying token
        uint256 initialPrincipal = 140_000 * tOne;
        uint256 initialShare = 100_000 * tOne;

        console2.log("twocrypto.last_prices() :>>", twocrypto.last_prices());

        // Setup initial AMM liquidity
        setUpAMM(AMMInit({user: makeAddr("bocchi"), share: initialShare, principal: initialPrincipal}));

        vm.startPrank(alice);
        deal(address(base), alice, 1e10 * bOne);
        base.approve(address(target), type(uint256).max);
        target.deposit(1e10 * bOne, alice);
        target.approve(address(principalToken), type(uint256).max);
        principalToken.issue(1e9 * tOne, alice); // fee may be charged
        vm.stopPrank();

        skip(1 days); // Advance time to accrue rewards
    }

    function getDxOffChain(TwoCryptoZap.SwapYtParams memory params) internal view returns (ApproxValue) {
        try this.ext_getDxOffChain(params) returns (uint256 result) {
            return ApproxValue.wrap(result);
        } catch {
            vm.assume(false);
            return ApproxValue.wrap(0); // silence warning
        }
    }

    /// @dev Helper function for `getDxOffChain` to catch the error
    function ext_getDxOffChain(TwoCryptoZap.SwapYtParams memory params) external view returns (uint256 result) {
        return
            TwoCryptoNGPreviewLib.binsearch_dx(twocrypto, Constants.TARGET_INDEX, Constants.PT_INDEX, params.principal);
    }

    function test_SwapUnderlying() public {
        setUpYield(int256(target.totalAssets() / 11)); // There is some yield in the vault

        Token tokenOut = Token.wrap(address(target));
        uint256 ytIn = 1000 * 10 ** yt.decimals();

        FeePcts newFeePcts = FeePctsLib.pack(3000, 100, 10, 100, 100);
        setFeePcts(newFeePcts);

        _test_Swap(alice, bob, tokenOut, ytIn);
    }

    function test_SwapBaseAsset() public {
        setUpYield(int256(target.totalAssets() / 11));

        Token tokenOut = Token.wrap(address(base));
        uint256 ytIn = 135 * 10 ** yt.decimals();

        FeePcts newFeePcts = FeePctsLib.pack(3000, 120, 310, 99, 100);
        setFeePcts(newFeePcts);

        _test_Swap(alice, bob, tokenOut, ytIn);
    }

    function testFuzz_SwapUnderlying(SetupAMMFuzzInput memory input, Token tokenOut, uint256 ytIn, FeePcts newFeePcts)
        public
        boundSetupAMMFuzzInput(input)
        fuzzAMMState(input)
    {
        tokenOut = boundToken(tokenOut);
        ytIn = bound(ytIn, 10_000, yt.totalSupply());

        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);

        _test_Swap(alice, bob, tokenOut, ytIn);
    }

    function _test_Swap(address caller, address receiver, Token token, uint256 principal) internal {
        uint256 oldYtBalnce = yt.balanceOf(caller);
        uint256 oldTokenBalance =
            token.isNative() ? receiver.balance : SafeTransferLib.balanceOf(token.unwrap(), receiver);

        principal = bound(principal, 0, yt.balanceOf(caller));

        TwoCryptoZap.SwapYtParams memory params = TwoCryptoZap.SwapYtParams({
            twoCrypto: twocrypto,
            tokenOut: token,
            principal: principal,
            receiver: receiver,
            amountOutMin: 0,
            deadline: block.timestamp
        });

        uint256 amountOut;
        {
            _approve(yt, caller, address(zap), principal);
            ApproxValue approx = getDxOffChain(params);
            uint256 _before = gasleft();
            vm.prank(caller);
            (bool s, bytes memory ret) = address(zap).call(abi.encodeCall(zap.swapYtForToken, (params, approx)));
            vm.assume(s);
            console2.log("gas usage: ", _before - gasleft());
            amountOut = abi.decode(ret, (uint256));
        }

        uint256 newTokenBalance =
            token.isNative() ? receiver.balance : SafeTransferLib.balanceOf(token.unwrap(), receiver);

        assertNoFundLeft();
        assertApproxEqRel(yt.balanceOf(caller), oldYtBalnce - params.principal, 0.0001e18, "yt balance");
        assertEq(newTokenBalance, oldTokenBalance + amountOut, "token balance");
    }

    function test_RevertWhen_BadToken() public {
        TwoCryptoZap.SwapYtParams memory params = toyParams();
        params.tokenOut = Token.wrap(address(0xcafe));
        params.principal = 10 * 10 ** yt.decimals();

        _approve(yt, alice, address(zap), type(uint256).max);
        ApproxValue approx = getDxOffChain(params);
        vm.expectRevert(Errors.ERC4626Connector_InvalidToken.selector);
        vm.prank(alice);
        zap.swapYtForToken(params, approx);
    }

    function test_RevertWhen_BadCallback() public {
        TwoCryptoZap.SwapYtParams memory params = toyParams();
        params.tokenOut = Token.wrap(address(target));
        params.principal = 10 * 10 ** yt.decimals();

        _approve(yt, alice, address(zap), type(uint256).max);
        ApproxValue approx = getDxOffChain(params);
        vm.prank(alice);
        zap.swapYtForToken(params, approx);

        vm.expectRevert(Errors.Zap_BadCallback.selector);
        zap.onUnite(333, 333, "jjj");
        vm.expectRevert(Errors.Zap_BadCallback.selector);
        zap.onSupply(100, 100, "jjj");
    }

    function test_RevertWhen_SlippageTooLarge_InsufficientSharesOut() public {
        vm.skip({skipTest: true});
    }

    function test_RevertWhen_SlippageTooLarge_InsufficientTokenOut() public {
        TwoCryptoZap.SwapYtParams memory params = toyParams();
        params.tokenOut = Token.wrap(address(target));
        params.amountOutMin = 1e24;

        _approve(yt, alice, address(zap), type(uint256).max);

        ApproxValue approx = getDxOffChain(params);
        vm.expectRevert();
        vm.prank(alice);
        zap.swapYtForToken(params, approx);
    }

    function test_RevertWhen_PullYieldTokenGreaterThanInput() public {
        TwoCryptoZap.SwapYtParams memory params = toyParams();
        params.tokenOut = Token.wrap(address(target));

        ApproxValue badApprox = getDxOffChain(params);

        // Increase underlying token price against PT so that the approximation result is outdated.

        deal(address(principalToken), bob, 5000 * bOne);
        vm.prank(bob);
        principalToken.transfer(twocrypto.unwrap(), 5000 * bOne);
        vm.prank(bob);
        twocrypto.exchange_received(Constants.PT_INDEX, Constants.TARGET_INDEX, 5000 * bOne, 0);
        skip(3 * 3600 seconds);

        vm.prank(alice);
        vm.expectRevert(Errors.Zap_PullYieldTokenGreaterThanInput.selector);
        zap.swapYtForToken(params, badApprox);
    }

    function test_WhenApproximationOutdated() public {
        TwoCryptoZap.SwapYtParams memory params = toyParams();
        params.tokenOut = Token.wrap(address(target));

        ApproxValue approx = getDxOffChain(params);
        ApproxValue badApprox = ApproxValue.wrap(approx.unwrap() * 70 / 100);

        // Decrease underlying token price against PT so that the approximation result is outdated.
        setUpYield(int256(10 * bOne));

        deal(address(target), bob, 5000 * tOne);
        vm.prank(bob);
        target.transfer(twocrypto.unwrap(), 5000 * tOne);
        vm.prank(bob);
        twocrypto.exchange_received(Constants.TARGET_INDEX, Constants.PT_INDEX, 5000 * tOne, 0);
        skip(3 * 3600 seconds);

        _approve(yt, alice, address(zap), type(uint256).max);
        vm.prank(alice);
        zap.swapYtForToken(params, badApprox);
        assertNoFundLeft(); // Nothing left on Zap
    }

    function test_RevertWhen_TransactionTooOld() public {
        TwoCryptoZap.SwapYtParams memory params = toyParams();
        params.deadline = block.timestamp - 1;

        ApproxValue approx = getDxOffChain(params);
        vm.expectRevert(Errors.Zap_TransactionTooOld.selector);
        vm.prank(alice);
        zap.swapYtForToken(params, approx);
    }

    function test_RevertWhen_NegativeYtPrice() public {
        TwoCryptoZap.SwapYtParams memory params = toyParams();
        params.tokenOut = Token.wrap(address(target));

        // Set up the AMM with PT price in asset greater than 1
        deal(address(target), bob, 100000 * tOne);
        vm.prank(bob);
        target.transfer(twocrypto.unwrap(), 100000 * tOne);
        vm.prank(bob);
        twocrypto.exchange_received(Constants.TARGET_INDEX, Constants.PT_INDEX, 100000 * tOne, 0);

        uint256 dy = twocrypto.get_dy(Constants.TARGET_INDEX, Constants.PT_INDEX, tOne);
        require(resolver.scale() > dy * 1e18 / bOne, "TEST:PT price in asset must be greater than 1");

        ApproxValue approx = getDxOffChain(params);
        _approve(yt, alice, address(zap), type(uint256).max);
        vm.expectRevert(Errors.Zap_InsufficientUnderlyingOutput.selector);
        vm.prank(alice);
        zap.swapYtForToken(params, approx);
    }

    function toyParams() internal view returns (TwoCryptoZap.SwapYtParams memory) {
        return TwoCryptoZap.SwapYtParams({
            twoCrypto: twocrypto,
            tokenOut: Token.wrap(address(base)),
            principal: bOne,
            receiver: alice,
            amountOutMin: 0,
            deadline: block.timestamp + 100 days
        });
    }
}

contract SwapYtForETHTest is SwapYtForTokenTest {
    function _deployTokens() internal override {
        _deployWETHVault();
    }

    function validTokenInput() internal view override returns (address[] memory tokens) {
        tokens = new address[](3);
        tokens[0] = address(target);
        tokens[1] = address(base);
        tokens[2] = NATIVE_ETH;
    }

    function test_SwapNativeETH() external {
        Token token = Token.wrap(NATIVE_ETH);
        uint256 ytIn = 10 ** yt.decimals();

        _test_Swap(alice, bob, token, ytIn);
    }
}
