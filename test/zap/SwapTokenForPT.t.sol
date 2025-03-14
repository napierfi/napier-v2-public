// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";

import {TwoCrypto, LibTwoCryptoNG} from "src/utils/LibTwoCryptoNG.sol";
import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Errors} from "src/Errors.sol";

import {Token} from "src/Types.sol";
import "src/types/Token.sol" as TokenType;

using {TokenType.intoToken} for address;

contract SwapTokenForPtTest is TwoCryptoZapAMMTest {
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
        deal(address(base), alice, 1e9 * bOne);
        base.approve(address(target), type(uint256).max);
        target.deposit(1e9 * bOne, alice);
        target.approve(address(principalToken), type(uint256).max);
        principalToken.issue(10_000 * tOne, alice); // fee may be charged
        vm.stopPrank();
    }

    modifier boundSetupAMMFuzzInput(SetupAMMFuzzInput memory input) override {
        uint256 price = twocrypto.last_prices(); // coin1 price in terms of coin0 in wei
        input.deposits[1] = bound(input.deposits[1], 1e6, 1_000 * tOne);
        input.deposits[0] = bound(input.deposits[0], 0, input.deposits[1] * price / 1e18);
        input.timestamp = bound(input.timestamp, block.timestamp, expiry + 180 days);
        input.yield = bound(input.yield, -1_000 * int256(bOne), int256(1_000 * bOne));
        _;
    }

    function test_SwapBaseAsset() public {
        setUpYield(int256(target.totalAssets() / 11));

        deal(address(base), alice, 1e6 * bOne);
        uint256 tokenIn = 1e6 * bOne;
        uint256 minPrincipal = 0;

        vm.startPrank(alice);
        base.approve(address(zap), tokenIn);
        uint256 ptOut = zap.swapTokenForPt(
            TwoCryptoZap.SwapTokenParams({
                twoCrypto: twocrypto,
                tokenIn: address(base).intoToken(),
                amountIn: tokenIn,
                minPrincipal: minPrincipal,
                receiver: bob,
                deadline: block.timestamp + 1 hours
            })
        );
        vm.stopPrank();
        assertGe(ptOut, minPrincipal, "ptOut >= minPrincipal expected");
        assertEq(principalToken.balanceOf(bob), ptOut, "bob balance");
        assertNoFundLeft();
    }

    function test_SwapUnderlying() public {
        setUpYield(int256(target.totalAssets() / 11));

        deal(address(target), alice, 1e6 * bOne);
        uint256 tokenIn = 1e6 * bOne;
        uint256 minPrincipal = 0;

        vm.startPrank(alice);
        target.approve(address(zap), tokenIn);
        uint256 ptOut = zap.swapTokenForPt(
            TwoCryptoZap.SwapTokenParams({
                twoCrypto: twocrypto,
                tokenIn: address(target).intoToken(),
                amountIn: tokenIn,
                minPrincipal: minPrincipal,
                receiver: bob,
                deadline: block.timestamp + 1 hours
            })
        );
        vm.stopPrank();
        assertGe(ptOut, minPrincipal, "ptOut >= minPrincipal expected");
        assertEq(principalToken.balanceOf(bob), ptOut, "bob balance");
        assertNoFundLeft();
    }

    function testFuzz_SwapBase(SetupAMMFuzzInput memory input, U256 memory tokenIn)
        public
        boundSetupAMMFuzzInput(input)
        fuzzAMMState(input)
    {
        vm.startPrank(alice);
        tokenIn.value = bound(tokenIn.value, 1e6, 1_000 * bOne);
        deal(address(base), alice, tokenIn.value);
        vm.warp(input.timestamp);

        base.approve(address(zap), tokenIn.value);
        uint256 ptOut = zap.swapTokenForPt(
            TwoCryptoZap.SwapTokenParams({
                twoCrypto: twocrypto,
                tokenIn: address(base).intoToken(),
                amountIn: tokenIn.value,
                minPrincipal: 100,
                receiver: bob,
                deadline: block.timestamp + 1 hours
            })
        );
        vm.stopPrank();
        assertGe(ptOut, 100, "ptOut >= minPrincipal expected");
        assertEq(principalToken.balanceOf(bob), ptOut, "bob balance");
        assertNoFundLeft();
    }

    function testFuzz_SwapUnderlying(SetupAMMFuzzInput memory input, U256 memory tokenIn)
        public
        boundSetupAMMFuzzInput(input)
        fuzzAMMState(input)
    {
        vm.startPrank(alice);
        tokenIn.value = bound(tokenIn.value, 1e6, 1_000 * bOne);
        deal(address(target), alice, tokenIn.value);
        vm.warp(input.timestamp);

        target.approve(address(zap), tokenIn.value);
        uint256 ptOut = zap.swapTokenForPt(
            TwoCryptoZap.SwapTokenParams({
                twoCrypto: twocrypto,
                tokenIn: address(target).intoToken(),
                amountIn: tokenIn.value,
                minPrincipal: 100,
                receiver: bob,
                deadline: block.timestamp + 1 hours
            })
        );
        vm.stopPrank();
        assertGe(ptOut, 100, "ptOut >= minPrincipal expected");
        assertEq(principalToken.balanceOf(bob), ptOut, "bob balance");
        assertNoFundLeft();
    }

    function test_RevertWhen_BadToken() public {
        deal(address(randomToken), address(this), 100);
        _approve(address(randomToken), address(this), address(zap), 100);
        TwoCryptoZap.SwapTokenParams memory params = TwoCryptoZap.SwapTokenParams({
            twoCrypto: twocrypto,
            tokenIn: address(randomToken).intoToken(),
            amountIn: 100,
            minPrincipal: 100,
            receiver: bob,
            deadline: block.timestamp + 1 hours
        });

        vm.expectRevert(Errors.ERC4626Connector_InvalidToken.selector);
        zap.swapTokenForPt(params);
    }

    function test_RevertWhen_TransactionTooOld() public {
        TwoCryptoZap.SwapTokenParams memory params = TwoCryptoZap.SwapTokenParams({
            twoCrypto: twocrypto,
            tokenIn: address(base).intoToken(),
            amountIn: 100,
            minPrincipal: 100,
            receiver: bob,
            deadline: block.timestamp - 1
        });

        vm.expectRevert(Errors.Zap_TransactionTooOld.selector);
        zap.swapTokenForPt(params);
    }

    function test_RevertWhen_SlippageTooHigh() public {
        TwoCryptoZap.SwapTokenParams memory params = TwoCryptoZap.SwapTokenParams({
            twoCrypto: twocrypto,
            tokenIn: address(base).intoToken(),
            amountIn: 100,
            minPrincipal: 100_000 * tOne,
            receiver: bob,
            deadline: block.timestamp + 1 hours
        });

        deal(address(base).intoToken(), alice, 100);
        vm.startPrank(alice);
        base.approve(address(zap), 100);

        vm.expectRevert(Errors.Zap_InsufficientPrincipalTokenOutput.selector);
        zap.swapTokenForPt(params);
        vm.stopPrank();
    }
}
