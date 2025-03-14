// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {ZapForkTest} from "../shared/Fork.t.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";

import {ITwoCrypto} from "../shared/ITwoCrypto.sol";
import "src/Types.sol";
import "src/Constants.sol";
import {Errors} from "src/Errors.sol";

import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {RouterPayload} from "src/modules/aggregator/AggregationRouter.sol";

using {TokenType.intoToken} for address;

contract SwapPtForAnyTokenTest is ZapForkTest {
    bytes constant ONEINCH_SWAP_CALL_DATA =
        hex"e2c95c8200000000000000000000000098e385f5a7e9bb5fd7a42435d14e63ed8a6570c7000000000000000000000000d9a442856c234a39a81a089c06451ebaa4306a7200000000000000000000000000000000000000000000000006c6589cc7c9306600000000000000000000000000000000000000000000000006d4a65126f3d77c280000000000000000000000bf7d01d6cddecb72c2369d1b421967098b10def79432a17f";

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 20976838);
    }

    function setUp() public virtual override {
        super.setUp();
        bob = 0x98E385F5a7E9Bb5Fd7A42435D14e63ed8A6570c7;
        uint256 amountWETH = 1 * 1e18;
        uint256 shares = 1 * 1e18;
        vm.startPrank(alice);
        deal(address(base), alice, amountWETH * 2);
        base.approve(address(target), amountWETH);
        shares = target.deposit(amountWETH, alice);

        target.approve(address(principalToken), type(uint256).max);

        uint256 amountPT = principalToken.supply(shares, alice);

        deal(address(base), alice, amountWETH);
        base.approve(address(target), amountWETH);

        shares = target.deposit(amountWETH, alice);

        // LP tokens
        target.approve(twocrypto.unwrap(), type(uint256).max);
        principalToken.approve(twocrypto.unwrap(), type(uint256).max);
        ITwoCrypto(twocrypto.unwrap()).add_liquidity([shares, amountPT], 0, alice);
        vm.stopPrank();
    }

    /// @dev Swap PT-pufETH -> [twoCrypto] -> pufETH -> [1inch] -> WETH
    function test_SwapPtForAnyToken() public {
        vm.startPrank(alice);
        uint256 amountWETH = 1 * 1e18;
        deal(address(base), alice, amountWETH * 2);
        base.approve(address(target), amountWETH);
        uint256 shares = target.deposit(amountWETH, alice);

        target.approve(address(principalToken), type(uint256).max);

        uint256 amountPT = principalToken.supply(shares, alice);
        principalToken.approve(address(zap), amountPT);
        RouterPayload memory swapData = RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_SWAP_CALL_DATA});

        uint256 amountOut = zap.swapPtForAnyToken(
            TwoCryptoZap.SwapPtParams({
                twoCrypto: twocrypto,
                tokenOut: WETH,
                principal: amountPT,
                receiver: bob,
                amountOutMin: 0,
                deadline: block.timestamp + 1 hours
            }),
            TwoCryptoZap.SwapTokenOutput({tokenRedeemShares: address(target).intoToken(), swapData: swapData})
        );

        assertGt(amountOut, 0, "Amount out should be greater than 0");
        assertEq(WETH.erc20().balanceOf(bob), amountOut, "Bob should receive the correct amount of WETH");
        assertNoFundLeft();
    }

    //scenario where amount is greater than swap aggregator so there is a leftover
    function test_SwapPtForAnyToken_WhenGreaterAmount() public {
        vm.startPrank(alice);
        uint256 amountWETH = 2 * 1e18;
        deal(address(base), alice, amountWETH * 2);
        base.approve(address(target), amountWETH);
        uint256 shares = target.deposit(amountWETH, alice);

        target.approve(address(principalToken), type(uint256).max);

        uint256 amountPT = principalToken.supply(shares, alice);
        principalToken.approve(address(zap), amountPT);
        RouterPayload memory swapData = RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_SWAP_CALL_DATA});

        uint256 amountOut = zap.swapPtForAnyToken(
            TwoCryptoZap.SwapPtParams({
                twoCrypto: twocrypto,
                tokenOut: WETH,
                principal: amountPT,
                receiver: bob,
                amountOutMin: 0,
                deadline: block.timestamp + 1 hours
            }),
            TwoCryptoZap.SwapTokenOutput({tokenRedeemShares: address(target).intoToken(), swapData: swapData})
        );

        assertGt(amountOut, 0, "Amount out should be greater than 0");
        assertEq(WETH.erc20().balanceOf(bob), amountOut, "Bob should receive the correct amount of WETH");
        assertNoFundLeft();
    }

    function test_RevertWhen_BadRouter() public {
        vm.startPrank(alice);
        uint256 amountWETH = 1 * 1e18;
        deal(address(base), alice, amountWETH * 2);
        base.approve(address(target), amountWETH);
        uint256 shares = target.deposit(amountWETH, alice);

        target.approve(address(principalToken), type(uint256).max);

        uint256 amountPT = principalToken.supply(shares, alice);
        principalToken.approve(address(zap), amountPT);
        RouterPayload memory swapData = RouterPayload({router: address(0), payload: ""});

        vm.expectRevert(Errors.AggregationRouter_UnsupportedRouter.selector);
        zap.swapPtForAnyToken(
            TwoCryptoZap.SwapPtParams({
                twoCrypto: twocrypto,
                tokenOut: WETH,
                principal: amountPT,
                receiver: bob,
                amountOutMin: 0,
                deadline: block.timestamp + 1 hours
            }),
            TwoCryptoZap.SwapTokenOutput({tokenRedeemShares: address(target).intoToken(), swapData: swapData})
        );

        vm.stopPrank();
    }

    function test_RevertWhen_InsufficientOutput() public {
        vm.startPrank(alice);
        uint256 amountWETH = 1 * 1e18;
        deal(address(base), alice, amountWETH * 2);
        base.approve(address(target), amountWETH);
        uint256 shares = target.deposit(amountWETH, alice);

        target.approve(address(principalToken), type(uint256).max);

        uint256 amountPT = principalToken.supply(shares, alice);
        principalToken.approve(address(zap), amountPT);

        RouterPayload memory swapData = RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_SWAP_CALL_DATA});

        vm.expectRevert(Errors.Zap_InsufficientTokenOutput.selector);
        zap.swapPtForAnyToken(
            TwoCryptoZap.SwapPtParams({
                twoCrypto: twocrypto,
                tokenOut: WETH,
                principal: amountPT,
                receiver: bob,
                amountOutMin: 2 * 1e18,
                deadline: block.timestamp + 1 hours
            }),
            TwoCryptoZap.SwapTokenOutput({tokenRedeemShares: address(target).intoToken(), swapData: swapData})
        );

        vm.stopPrank();
    }

    function test_RevertWhen_TransactionTooOld() public {
        RouterPayload memory swapData = RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_SWAP_CALL_DATA});

        vm.expectRevert(Errors.Zap_TransactionTooOld.selector);
        zap.swapPtForAnyToken(
            TwoCryptoZap.SwapPtParams({
                twoCrypto: twocrypto,
                tokenOut: WETH,
                principal: 212121211,
                receiver: bob,
                amountOutMin: 2 * 1e18,
                deadline: block.timestamp - 1
            }),
            TwoCryptoZap.SwapTokenOutput({tokenRedeemShares: address(target).intoToken(), swapData: swapData})
        );
    }
}
