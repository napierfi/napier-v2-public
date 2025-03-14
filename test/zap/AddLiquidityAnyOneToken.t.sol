// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {ZapForkTest} from "../shared/Fork.t.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {ITwoCrypto} from "../shared/ITwoCrypto.sol";
import "src/Types.sol";
import "src/Constants.sol" as Constants;
import {Errors} from "src/Errors.sol";

import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {RouterPayload} from "src/modules/aggregator/AggregationRouter.sol";

using {TokenType.intoToken} for address;

contract AddLiquidityAnyOneTokenTest is ZapForkTest {
    /// @notice Oneinch swap call data for USDC (1000000000) -> WETH
    bytes constant ONEINCH_SWAP_CALL_DATA =
        hex"e2c95c82000000000000000000000000000c632910d6be3ef6601420bb35dab2a6f2ede7000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000003b9aca00000000000000000000000000000000000000000000000000053ea141195e6c75288000000000000000000000e0554a476a092703abdb3ef35c80e0d76d32939f9432a17f";

    /// @notice Oneinch swap call data for USDC (1000000000) -> ETH
    bytes constant ONEINCH_SWAP_CALL_DATA_NATIVE =
        hex"e2c95c82000000000000000000000000000c632910d6be3ef6601420bb35dab2a6f2ede7000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000003b9aca00000000000000000000000000000000000000000000000000053e116edcd01e7a388000000000000000000000e0554a476a092703abdb3ef35c80e0d76d32939f9432a17f";

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

    /// @notice Test USDC -> [1inch] -> WETH -> [connector] -> pufETH -> LP + YT
    function test_AddLiquidityAnyOneToken() public {
        vm.startPrank(alice);
        uint256 amountUSDC = 1000 * 1e6;
        deal(USDC, alice, amountUSDC);
        USDC.erc20().approve(address(zap), amountUSDC);

        RouterPayload memory swapData = RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_SWAP_CALL_DATA});

        uint256 beforeBalanceLP = ERC20(address(twocrypto.unwrap())).balanceOf(bob);
        uint256 beforeBalanceYT = principalToken.i_yt().balanceOf(bob);

        TwoCryptoZap.AddLiquidityOneTokenParams memory params = TwoCryptoZap.AddLiquidityOneTokenParams({
            twoCrypto: twocrypto,
            tokenIn: USDC,
            amountIn: amountUSDC,
            minLiquidity: 0,
            minYt: 0,
            receiver: bob,
            deadline: block.timestamp + 1 hours
        });

        TwoCryptoZap.SwapTokenInput memory tokenInput =
            TwoCryptoZap.SwapTokenInput({tokenMintShares: WETH, swapData: swapData});

        (uint256 liquidity, uint256 ytOut) = zap.addLiquidityAnyOneToken(params, tokenInput);

        assertGt(liquidity, 0, "LP output should be greater than zero");
        assertGt(ytOut, 0, "YT output should be greater than zero");
        assertEq(
            ERC20(address(twocrypto.unwrap())).balanceOf(bob),
            beforeBalanceLP + liquidity,
            "Bob should receive the correct amount of LP tokens"
        );
        assertEq(
            principalToken.i_yt().balanceOf(bob), beforeBalanceYT + ytOut, "Bob should receive the correct amount of YT"
        );
        assertEq(USDC.erc20().balanceOf(alice), 0, "All USDC should be spent");
        assertNoFundLeft();
    }

    /// @notice Test USDC -> [1inch] -> ETH -> [connector] -> pufETH -> LP + YT
    function test_AddLiquidityAnyOneTokenNative() public {
        vm.startPrank(alice);
        uint256 amountUSDC = 1000 * 1e6;
        deal(USDC, alice, amountUSDC);
        USDC.erc20().approve(address(zap), amountUSDC);

        RouterPayload memory swapData = RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_SWAP_CALL_DATA_NATIVE});

        uint256 beforeBalanceLP = ERC20(address(twocrypto.unwrap())).balanceOf(bob);
        uint256 beforeBalanceYT = principalToken.i_yt().balanceOf(bob);

        TwoCryptoZap.AddLiquidityOneTokenParams memory params = TwoCryptoZap.AddLiquidityOneTokenParams({
            twoCrypto: twocrypto,
            tokenIn: USDC,
            amountIn: amountUSDC,
            minLiquidity: 0,
            minYt: 0,
            receiver: bob,
            deadline: block.timestamp + 1 hours
        });

        TwoCryptoZap.SwapTokenInput memory tokenInput =
            TwoCryptoZap.SwapTokenInput({tokenMintShares: Constants.NATIVE_ETH.intoToken(), swapData: swapData});

        (uint256 liquidity, uint256 ytOut) = zap.addLiquidityAnyOneToken(params, tokenInput);

        assertGt(liquidity, 0, "LP output should be greater than zero");
        assertGt(ytOut, 0, "YT output should be greater than zero");
        assertEq(
            ERC20(address(twocrypto.unwrap())).balanceOf(bob),
            beforeBalanceLP + liquidity,
            "Bob should receive the correct amount of LP tokens"
        );
        assertEq(
            principalToken.i_yt().balanceOf(bob), beforeBalanceYT + ytOut, "Bob should receive the correct amount of YT"
        );
        assertEq(USDC.erc20().balanceOf(alice), 0, "All USDC should be spent");
        assertNoFundLeft();
    }

    function test_RevertWhen_BadRouter() public {
        vm.startPrank(alice);
        uint256 amountUSDC = 1000 * 1e6;
        deal(USDC, alice, amountUSDC);
        USDC.erc20().approve(address(zap), amountUSDC);

        RouterPayload memory swapData = RouterPayload({router: address(0), payload: ""});

        TwoCryptoZap.AddLiquidityOneTokenParams memory params = TwoCryptoZap.AddLiquidityOneTokenParams({
            twoCrypto: twocrypto,
            tokenIn: USDC,
            amountIn: amountUSDC,
            minLiquidity: 0,
            minYt: 0,
            receiver: bob,
            deadline: block.timestamp + 1 hours
        });

        TwoCryptoZap.SwapTokenInput memory tokenInput =
            TwoCryptoZap.SwapTokenInput({tokenMintShares: address(target).intoToken(), swapData: swapData});

        vm.expectRevert(Errors.AggregationRouter_UnsupportedRouter.selector);
        zap.addLiquidityAnyOneToken(params, tokenInput);

        vm.stopPrank();
    }

    function test_RevertWhen_InsufficientYTOutput() public {
        vm.startPrank(alice);
        uint256 amountUSDC = 1000 * 1e6;
        deal(USDC, alice, amountUSDC);
        USDC.erc20().approve(address(zap), amountUSDC);

        RouterPayload memory swapData = RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_SWAP_CALL_DATA});

        TwoCryptoZap.AddLiquidityOneTokenParams memory params = TwoCryptoZap.AddLiquidityOneTokenParams({
            twoCrypto: twocrypto,
            tokenIn: USDC,
            amountIn: amountUSDC,
            minLiquidity: 0,
            minYt: type(uint256).max, // Set unreachable minimum YT output
            receiver: bob,
            deadline: block.timestamp + 1 hours
        });

        TwoCryptoZap.SwapTokenInput memory tokenInput =
            TwoCryptoZap.SwapTokenInput({tokenMintShares: WETH, swapData: swapData});

        vm.expectRevert(Errors.Zap_InsufficientYieldTokenOutput.selector);
        zap.addLiquidityAnyOneToken(params, tokenInput);
        vm.stopPrank();
    }

    function test_RevertWhen_TransactionTooOld() public {
        TwoCryptoZap.AddLiquidityOneTokenParams memory params = TwoCryptoZap.AddLiquidityOneTokenParams({
            twoCrypto: twocrypto,
            tokenIn: USDC,
            amountIn: 1000 * 1e6,
            minLiquidity: 0,
            minYt: 0,
            receiver: bob,
            deadline: block.timestamp - 1 // Set expired deadline
        });

        RouterPayload memory swapData = RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_SWAP_CALL_DATA});
        TwoCryptoZap.SwapTokenInput memory tokenInput =
            TwoCryptoZap.SwapTokenInput({tokenMintShares: WETH, swapData: swapData});

        vm.expectRevert(Errors.Zap_TransactionTooOld.selector);
        zap.addLiquidityAnyOneToken(params, tokenInput);
    }

    function test_RevertWhen_NonNativeTokenWithValue() public {
        vm.startPrank(alice);
        uint256 amountUSDC = 1000 * 1e6;
        deal(USDC, alice, amountUSDC);
        deal(alice, 1 ether);
        USDC.erc20().approve(address(zap), amountUSDC);

        RouterPayload memory swapData = RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_SWAP_CALL_DATA});

        TwoCryptoZap.AddLiquidityOneTokenParams memory params = TwoCryptoZap.AddLiquidityOneTokenParams({
            twoCrypto: twocrypto,
            tokenIn: USDC,
            amountIn: amountUSDC,
            minLiquidity: 0,
            minYt: 0,
            receiver: bob,
            deadline: block.timestamp + 1 hours
        });

        TwoCryptoZap.SwapTokenInput memory tokenInput =
            TwoCryptoZap.SwapTokenInput({tokenMintShares: WETH, swapData: swapData});

        vm.expectRevert(Errors.Zap_InconsistentETHReceived.selector);
        zap.addLiquidityAnyOneToken{value: 1 ether}(params, tokenInput); // Sending ETH with USDC transaction

        vm.stopPrank();
    }
}
