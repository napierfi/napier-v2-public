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

contract SwapAnyTokenForPtTest is ZapForkTest {
    bytes constant ONEINCH_SWAP_CALL_DATA =
        hex"e2c95c82000000000000000000000000000c632910d6be3ef6601420bb35dab2a6f2ede7000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000003b9aca00000000000000000000000000000000000000000000000000053ea141195e6c75288000000000000000000000e0554a476a092703abdb3ef35c80e0d76d32939f9432a17f";

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 20976838);
    }

    function setUp() public virtual override {
        super.setUp();

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

    /// @notice Swap USDC -> [1inch] -> WETH -> [connector] -> pufETH -> [twoCrypto] -> PT-pufETH
    function test_SwapAnyTokenForPt() public {
        vm.startPrank(alice);
        uint256 amountUSDC = 1000 * 1e6;
        deal(USDC, alice, amountUSDC);
        USDC.erc20().approve(address(zap), amountUSDC);

        RouterPayload memory swapData = RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_SWAP_CALL_DATA});

        TwoCryptoZap.SwapTokenParams memory params = TwoCryptoZap.SwapTokenParams({
            twoCrypto: twocrypto,
            tokenIn: USDC,
            amountIn: amountUSDC,
            minPrincipal: 0,
            receiver: bob,
            deadline: block.timestamp + 1 hours
        });

        TwoCryptoZap.SwapTokenInput memory tokenInput =
            TwoCryptoZap.SwapTokenInput({tokenMintShares: WETH, swapData: swapData});

        uint256 ptOut = zap.swapAnyTokenForPt(params, tokenInput);

        assertGt(ptOut, 0, "PT output should be greater than zero");
        assertEq(principalToken.balanceOf(bob), ptOut, "Bob should receive the correct amount of PT");
        assertEq(USDC.erc20().balanceOf(alice), 0, "All USDC should be spent");
        assertNoFundLeft();
    }

    function test_RevertWhen_BadRouter() public {
        vm.startPrank(alice);
        uint256 amountUSDC = 1000 * 1e6; // 1000 USDC
        deal(USDC, alice, amountUSDC);
        USDC.erc20().approve(address(zap), amountUSDC);

        RouterPayload memory swapData = RouterPayload({router: address(0), payload: ""});

        TwoCryptoZap.SwapTokenParams memory params = TwoCryptoZap.SwapTokenParams({
            twoCrypto: twocrypto,
            tokenIn: USDC,
            amountIn: amountUSDC,
            minPrincipal: 0,
            receiver: bob,
            deadline: block.timestamp + 1 hours
        });

        TwoCryptoZap.SwapTokenInput memory tokenInput =
            TwoCryptoZap.SwapTokenInput({tokenMintShares: address(target).intoToken(), swapData: swapData});

        vm.expectRevert(Errors.AggregationRouter_UnsupportedRouter.selector);
        zap.swapAnyTokenForPt(params, tokenInput);

        vm.stopPrank();
    }

    function test_RevertWhen_InsufficientOutput() public {
        vm.startPrank(alice);
        uint256 amountUSDC = 1000 * 1e6;
        deal(USDC, alice, amountUSDC);
        USDC.erc20().approve(address(zap), amountUSDC);

        RouterPayload memory swapData = RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_SWAP_CALL_DATA});

        TwoCryptoZap.SwapTokenParams memory params = TwoCryptoZap.SwapTokenParams({
            twoCrypto: twocrypto,
            tokenIn: USDC,
            amountIn: amountUSDC,
            minPrincipal: type(uint256).max,
            receiver: bob,
            deadline: block.timestamp + 1 hours
        });

        TwoCryptoZap.SwapTokenInput memory tokenInput =
            TwoCryptoZap.SwapTokenInput({tokenMintShares: WETH, swapData: swapData});
        vm.expectRevert(Errors.Zap_InsufficientPrincipalTokenOutput.selector);
        zap.swapAnyTokenForPt(params, tokenInput);
        vm.stopPrank();
    }

    function test_RevertWhen_TransactionTooOld() public {
        TwoCryptoZap.SwapTokenParams memory params = TwoCryptoZap.SwapTokenParams({
            twoCrypto: twocrypto,
            tokenIn: USDC,
            amountIn: 23121121,
            minPrincipal: type(uint256).max,
            receiver: bob,
            deadline: block.timestamp - 1
        });

        RouterPayload memory swapData = RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_SWAP_CALL_DATA});
        TwoCryptoZap.SwapTokenInput memory tokenInput =
            TwoCryptoZap.SwapTokenInput({tokenMintShares: WETH, swapData: swapData});

        vm.expectRevert(Errors.Zap_TransactionTooOld.selector);
        zap.swapAnyTokenForPt(params, tokenInput);
    }

    function test_RevertWhen_NonNativeTokenWithValue() public {
        vm.startPrank(alice);
        uint256 amountUSDC = 1000 * 1e6;
        deal(USDC, alice, amountUSDC);
        deal(alice, 1 ether);
        USDC.erc20().approve(address(zap), amountUSDC);

        RouterPayload memory swapData = RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_SWAP_CALL_DATA});

        TwoCryptoZap.SwapTokenParams memory params = TwoCryptoZap.SwapTokenParams({
            twoCrypto: twocrypto,
            tokenIn: USDC,
            amountIn: amountUSDC,
            minPrincipal: 0,
            receiver: bob,
            deadline: block.timestamp + 1 hours
        });

        TwoCryptoZap.SwapTokenInput memory tokenInput =
            TwoCryptoZap.SwapTokenInput({tokenMintShares: WETH, swapData: swapData});

        vm.expectRevert(Errors.Zap_InconsistentETHReceived.selector);
        zap.swapAnyTokenForPt{value: 1 ether}(params, tokenInput);

        vm.stopPrank();
    }
}
