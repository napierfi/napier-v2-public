// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {ZapForkTest} from "../shared/Fork.t.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {ITwoCrypto} from "../shared/ITwoCrypto.sol";
import "src/Types.sol";
import "src/Constants.sol";
import {Errors} from "src/Errors.sol";

import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {RouterPayload} from "src/modules/aggregator/AggregationRouter.sol";
import {Quoter} from "src/lens/Quoter.sol";

using {TokenType.intoToken} for address;

contract SwapAnyTokenForYTTest is ZapForkTest {
    bytes constant OPEN_OCEAN_SWAP_CALL_DATA =
        hex"bc80f1a8000000000000000000000000000c632910d6be3ef6601420bb35dab2a6f2ede7000000000000000000000000000000000000000000000000000000003b9aca0000000000000000000000000000000000000000000000000005059cc8abe40be2000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000010001f4000000000000000000e0554a476a092703abdb3ef35c80e0d76d32939f";
    ApproxValue constant DEFAULT_SHARES_FLASH_BORROW = ApproxValue.wrap(0);

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 20976838);
    }

    function setUp() public virtual override {
        super.setUp();
        uint256 amountWETH = 10 * 1e18;
        vm.startPrank(alice);
        deal(address(base), alice, amountWETH);
        base.approve(address(target), amountWETH);
        uint256 shares = target.deposit(amountWETH, alice);

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

    /// @notice Swap USDC -> [1inch] -> WETH -> [connector] -> pufETH -> [twoCrypto] -> YT-pufETH
    function test_SwapAnyTokenForYT() public {
        vm.startPrank(alice);
        uint256 amountUSDC = 1000 * 1e6;
        deal(USDC, alice, amountUSDC);
        USDC.erc20().approve(address(zap), amountUSDC);
        RouterPayload memory swapData = RouterPayload({router: OPEN_OCEAN_ROUTER, payload: OPEN_OCEAN_SWAP_CALL_DATA});
        uint256 beforeBalanceYT = principalToken.i_yt().balanceOf(bob);

        uint256 guessYt;
        ApproxValue sharesFlashBorrow;
        {
            (bool s1, bytes memory ret1) = address(quoter).staticcall(
                abi.encodeCall(quoter.previewSwapTokenForYt, (twocrypto, WETH, 378958500369230582)) // this number i got from offchain api
            );
            vm.assume(s1);
            (guessYt, sharesFlashBorrow,) = abi.decode(ret1, (uint256, ApproxValue, uint256));
            vm.assume(sharesFlashBorrow.unwrap() > 10);
        }

        uint256 ytOut = zap.swapAnyTokenForYt(
            TwoCryptoZap.SwapTokenParams({
                twoCrypto: twocrypto,
                tokenIn: USDC,
                amountIn: amountUSDC,
                minPrincipal: 1 * 1e16,
                receiver: bob,
                deadline: block.timestamp + 1 hours
            }),
            sharesFlashBorrow,
            TwoCryptoZap.SwapTokenInput({tokenMintShares: WETH, swapData: swapData})
        );

        assertGt(ytOut, 0, "YT out should be greater than 0");
        assertEq(
            principalToken.i_yt().balanceOf(bob), beforeBalanceYT + ytOut, "Bob should receive the correct amount of YT"
        );
        assertNoFundLeft();
    }

    function test_RevertWhen_BadRouter() public {
        vm.startPrank(alice);
        uint256 amountUSDC = 1000 * 1e6;
        deal(USDC, alice, amountUSDC);
        USDC.erc20().approve(address(zap), amountUSDC);
        RouterPayload memory swapData = RouterPayload({router: address(0), payload: ""});

        vm.expectRevert(Errors.AggregationRouter_UnsupportedRouter.selector);
        zap.swapAnyTokenForYt(
            TwoCryptoZap.SwapTokenParams({
                twoCrypto: twocrypto,
                tokenIn: USDC,
                amountIn: amountUSDC,
                minPrincipal: 1 * 1e16,
                receiver: bob,
                deadline: block.timestamp + 1 hours
            }),
            DEFAULT_SHARES_FLASH_BORROW,
            TwoCryptoZap.SwapTokenInput({tokenMintShares: address(target).intoToken(), swapData: swapData})
        );

        vm.stopPrank();
    }

    function test_RevertWhen_InsufficientOutput() public {
        vm.startPrank(alice);
        uint256 amountUSDC = 1000 * 1e6;
        deal(USDC, alice, amountUSDC);
        USDC.erc20().approve(address(zap), amountUSDC);

        RouterPayload memory swapData = RouterPayload({router: OPEN_OCEAN_ROUTER, payload: OPEN_OCEAN_SWAP_CALL_DATA});

        uint256 guessYt;
        ApproxValue sharesFlashBorrow;
        {
            (bool s1, bytes memory ret1) = address(quoter).staticcall(
                abi.encodeCall(quoter.previewSwapTokenForYt, (twocrypto, WETH, 378958500369230582)) // this number i got from offchain api
            );
            vm.assume(s1);
            (guessYt, sharesFlashBorrow,) = abi.decode(ret1, (uint256, ApproxValue, uint256));
            vm.assume(sharesFlashBorrow.unwrap() > 10);
        }

        vm.expectRevert(Errors.Zap_InsufficientYieldTokenOutput.selector);
        zap.swapAnyTokenForYt(
            TwoCryptoZap.SwapTokenParams({
                twoCrypto: twocrypto,
                tokenIn: USDC,
                amountIn: amountUSDC,
                minPrincipal: 10000 * 1e16,
                receiver: bob,
                deadline: block.timestamp + 1 hours
            }),
            sharesFlashBorrow,
            TwoCryptoZap.SwapTokenInput({tokenMintShares: WETH, swapData: swapData})
        );

        vm.stopPrank();
    }

    function test_RevertWhen_TransactionTooOld() public {
        vm.startPrank(alice);
        uint256 amountWETH = 1 * 1e18;
        deal(address(base), alice, amountWETH * 2);
        base.approve(address(zap), amountWETH);
        RouterPayload memory swapData = RouterPayload({router: OPEN_OCEAN_ROUTER, payload: OPEN_OCEAN_SWAP_CALL_DATA});

        vm.expectRevert(Errors.Zap_TransactionTooOld.selector);
        zap.swapAnyTokenForYt(
            TwoCryptoZap.SwapTokenParams({
                twoCrypto: twocrypto,
                tokenIn: WETH,
                amountIn: amountWETH,
                minPrincipal: 1 * 1e16,
                receiver: bob,
                deadline: block.timestamp - 1
            }),
            DEFAULT_SHARES_FLASH_BORROW,
            TwoCryptoZap.SwapTokenInput({tokenMintShares: address(target).intoToken(), swapData: swapData})
        );

        vm.stopPrank();
    }

    function test_RevertWhen_NonNativeTokenWithValue() public {
        vm.startPrank(alice);
        uint256 amountUSDC = 1000 * 1e6;
        deal(USDC, alice, amountUSDC);
        deal(alice, 1 ether);
        USDC.erc20().approve(address(zap), amountUSDC);

        RouterPayload memory swapData = RouterPayload({router: OPEN_OCEAN_ROUTER, payload: OPEN_OCEAN_SWAP_CALL_DATA});

        uint256 guessYt;
        ApproxValue sharesFlashBorrow;
        {
            (bool s1, bytes memory ret1) = address(quoter).staticcall(
                abi.encodeCall(quoter.previewSwapTokenForYt, (twocrypto, WETH, 378958500369230582))
            );
            vm.assume(s1);
            (guessYt, sharesFlashBorrow,) = abi.decode(ret1, (uint256, ApproxValue, uint256));
            vm.assume(sharesFlashBorrow.unwrap() > 10);
        }

        vm.expectRevert(Errors.Zap_InconsistentETHReceived.selector);
        zap.swapAnyTokenForYt{value: 1 ether}( // Sending ETH with USDC transaction
            TwoCryptoZap.SwapTokenParams({
                twoCrypto: twocrypto,
                tokenIn: USDC,
                amountIn: amountUSDC,
                minPrincipal: 1 * 1e16,
                receiver: bob,
                deadline: block.timestamp + 1 hours
            }),
            sharesFlashBorrow,
            TwoCryptoZap.SwapTokenInput({tokenMintShares: WETH, swapData: swapData})
        );

        vm.stopPrank();
    }
}
