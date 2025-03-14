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

contract SwapPtForTokenTest is TwoCryptoZapAMMTest {
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

    function test_SwapUnderlying() public {
        uint256 ptIn = 10 * 10 ** principalToken.decimals();
        uint256 minAmount = 0;

        vm.startPrank(alice);
        principalToken.approve(address(zap), ptIn);
        uint256 amountOut = zap.swapPtForToken(
            TwoCryptoZap.SwapPtParams({
                twoCrypto: twocrypto,
                tokenOut: address(target).intoToken(),
                principal: ptIn,
                receiver: bob,
                amountOutMin: minAmount,
                deadline: block.timestamp + 1 hours
            })
        );
        assertGe(amountOut, minAmount, "amountOut >= minAmount expected");
        assertEq(target.balanceOf(bob), amountOut, "bob balance");
        assertNoFundLeft();
        vm.stopPrank();
    }

    function test_SwapBaseAsset() public {
        uint256 ptIn = 10 * 10 ** principalToken.decimals();
        uint256 minAmount = 0;

        vm.startPrank(alice);
        principalToken.approve(address(zap), ptIn);
        uint256 amountOut = zap.swapPtForToken(
            TwoCryptoZap.SwapPtParams({
                twoCrypto: twocrypto,
                tokenOut: address(base).intoToken(),
                principal: ptIn,
                receiver: bob,
                amountOutMin: minAmount,
                deadline: block.timestamp + 1 hours
            })
        );
        assertGe(amountOut, minAmount, "amountOut >= minAmount expected");
        assertEq(base.balanceOf(bob), amountOut, "bob balance");
        assertNoFundLeft();
        vm.stopPrank();
    }

    function testFuzz_SwapUnderlying(SetupAMMFuzzInput memory input, U256 memory ptIn)
        public
        boundSetupAMMFuzzInput(input)
        fuzzAMMState(input)
    {
        vm.startPrank(alice);
        ptIn.value = bound(ptIn.value, 1e6, 1_000 * tOne);

        principalToken.approve(address(zap), ptIn.value);
        uint256 amountOut = zap.swapPtForToken(
            TwoCryptoZap.SwapPtParams({
                twoCrypto: twocrypto,
                tokenOut: address(target).intoToken(),
                principal: ptIn.value,
                receiver: bob,
                amountOutMin: 100,
                deadline: block.timestamp + 1 hours
            })
        );
        vm.stopPrank();
        assertGe(amountOut, 100, "amountOut >= minAmount expected");
        assertEq(target.balanceOf(bob), amountOut, "bob balance");
        assertNoFundLeft();
    }

    function testFuzz_SwapBase(SetupAMMFuzzInput memory input, U256 memory ptIn)
        public
        boundSetupAMMFuzzInput(input)
        fuzzAMMState(input)
    {
        vm.startPrank(alice);
        ptIn.value = bound(ptIn.value, 1e6, 1_000 * tOne);

        principalToken.approve(address(zap), ptIn.value);
        uint256 amountOut = zap.swapPtForToken(
            TwoCryptoZap.SwapPtParams({
                twoCrypto: twocrypto,
                tokenOut: address(base).intoToken(),
                principal: ptIn.value,
                receiver: bob,
                amountOutMin: 100,
                deadline: block.timestamp + 1 hours
            })
        );
        vm.stopPrank();
        assertGe(amountOut, 100, "amountOut >= minAmount expected");
        assertEq(base.balanceOf(bob), amountOut, "bob balance");
        assertNoFundLeft();
    }

    function test_RevertWhen_BadToken() public {
        TwoCryptoZap.SwapPtParams memory params = TwoCryptoZap.SwapPtParams({
            twoCrypto: twocrypto,
            tokenOut: address(randomToken).intoToken(),
            principal: 100,
            receiver: bob,
            amountOutMin: 100,
            deadline: block.timestamp + 1 hours
        });
        vm.startPrank(alice);
        principalToken.approve(address(zap), 100);

        vm.expectRevert(Errors.ERC4626Connector_InvalidToken.selector);
        zap.swapPtForToken(params);
        vm.stopPrank();
    }

    function test_RevertWhen_TransactionTooOld() public {
        TwoCryptoZap.SwapPtParams memory params = TwoCryptoZap.SwapPtParams({
            twoCrypto: twocrypto,
            tokenOut: address(target).intoToken(),
            principal: 100,
            receiver: bob,
            amountOutMin: 100,
            deadline: block.timestamp - 1
        });

        vm.expectRevert(Errors.Zap_TransactionTooOld.selector);
        zap.swapPtForToken(params);
    }

    function test_RevertWhen_SlippageTooHigh() public {
        TwoCryptoZap.SwapPtParams memory params = TwoCryptoZap.SwapPtParams({
            twoCrypto: twocrypto,
            tokenOut: address(target).intoToken(),
            principal: 100,
            receiver: bob,
            amountOutMin: 100_000 * tOne,
            deadline: block.timestamp + 1 hours
        });

        vm.startPrank(alice);
        principalToken.approve(address(zap), 100);

        vm.expectRevert(Errors.Zap_InsufficientTokenOutput.selector);
        zap.swapPtForToken(params);
        vm.stopPrank();
    }
}
