// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {ZapForkTest} from "../shared/Fork.t.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";

import {ITwoCrypto} from "../shared/ITwoCrypto.sol";
import "src/Types.sol";
import "src/Constants.sol" as Constants;
import {Errors} from "src/Errors.sol";

import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {RouterPayload} from "src/modules/aggregator/AggregationRouter.sol";

using {TokenType.intoToken} for address;

contract RedeemAnyTokenTest is ZapForkTest {
    // asset: WETH -> USDC
    // ca: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 -> 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    // amount: 990099009900990097
    bytes constant ONEINCH_SWAP_CALL_DATA =
        hex"e2c95c820000000000000000000000001d96f2f6bef1202e4ce1ff6dad0c2cb002861d3e000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000000000000000000000000000000dbd89cdc19d4e910000000000000000000000000000000000000000000000000000000093e38d7e28000000000000000000000088e6a0c2ddd26feeb64f039a2c41296fcb3f56409432a17f";

    // asset: ETH -> USDC
    // ca: 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE -> 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    // amount: 990099009900990097
    bytes constant ONEINCH_SWAP_CALL_DATA_NATIVE =
        hex"175accdc0000000000000000000000001d96f2f6bef1202e4ce1ff6dad0c2cb002861d3e0000000000000000000000000000000000000000000000000000000098848db100000000000000003b6d0340b4e16d0168e52d35cacd2c6185b44281ec28c9dc9432a17f";

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 20976838);
    }

    function setUp() public virtual override {
        super.setUp();

        uint256 amountWETH = 1 * 1e18;
        vm.startPrank(alice);
        deal(address(base), alice, amountWETH);
        base.approve(address(target), amountWETH);
        uint256 shares = target.deposit(amountWETH, alice);

        target.approve(address(principalToken), type(uint256).max);
        principalToken.supply(shares, alice);
        vm.stopPrank();
    }

    /// @notice Redeem PT -> [principalToken] -> shares -> [connector] -> WETH -> [1inch] -> USDC
    function test_redeemToAnyToken() public {
        vm.startPrank(alice);
        uint256 principal = principalToken.balanceOf(alice);
        uint256 minAmount = 0;
        vm.warp(expiry + 1000);
        principalToken.approve(address(zap), principal);

        RouterPayload memory swapData = RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_SWAP_CALL_DATA});

        TwoCryptoZap.SwapTokenOutput memory tokenOutput =
            TwoCryptoZap.SwapTokenOutput({tokenRedeemShares: WETH, swapData: swapData});

        uint256 beforeBalanceUSDC = USDC.erc20().balanceOf(bob);

        uint256 amountOut = zap.redeemToAnyToken(principalToken, USDC, principal, bob, minAmount, tokenOutput);

        assertGt(amountOut, 0, "USDC output should be greater than zero");
        assertEq(
            USDC.erc20().balanceOf(bob), beforeBalanceUSDC + amountOut, "Bob should receive the correct amount of USDC"
        );
        assertEq(principalToken.balanceOf(alice), 0, "All PT should be spent");
        assertNoFundLeft();
    }

    /// @notice Redeem PT -> [principalToken] -> shares -> [connector] -> ETH -> [1inch] -> USDC
    function test_redeemToAnyTokenNative() public {
        vm.startPrank(alice);
        uint256 principal = principalToken.balanceOf(alice);
        uint256 minAmount = 0;
        vm.warp(expiry + 1000);
        principalToken.approve(address(zap), principal);

        RouterPayload memory swapData = RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_SWAP_CALL_DATA_NATIVE});

        TwoCryptoZap.SwapTokenOutput memory tokenOutput =
            TwoCryptoZap.SwapTokenOutput({tokenRedeemShares: Constants.NATIVE_ETH.intoToken(), swapData: swapData});

        uint256 beforeBalanceUSDC = USDC.erc20().balanceOf(bob);

        uint256 amountOut = zap.redeemToAnyToken(principalToken, USDC, principal, bob, minAmount, tokenOutput);

        assertGt(amountOut, 0, "USDC output should be greater than zero");
        assertEq(
            USDC.erc20().balanceOf(bob), beforeBalanceUSDC + amountOut, "Bob should receive the correct amount of USDC"
        );
        assertEq(principalToken.balanceOf(alice), 0, "All PT should be spent");
        assertNoFundLeft();
    }

    function test_RevertWhen_BadRouter() public {
        vm.startPrank(alice);
        vm.warp(expiry + 1000);
        uint256 principal = principalToken.balanceOf(alice);

        principalToken.approve(address(zap), principal);

        RouterPayload memory swapData = RouterPayload({router: address(0), payload: ""});

        TwoCryptoZap.SwapTokenOutput memory tokenOutput =
            TwoCryptoZap.SwapTokenOutput({tokenRedeemShares: WETH, swapData: swapData});

        vm.expectRevert(Errors.AggregationRouter_UnsupportedRouter.selector);
        zap.redeemToAnyToken(principalToken, USDC, principal, bob, 0, tokenOutput);

        vm.stopPrank();
    }

    function test_RevertWhen_InsufficientOutput() public {
        vm.startPrank(alice);
        vm.warp(expiry + 1000);
        uint256 principal = principalToken.balanceOf(alice);
        uint256 minAmount = type(uint256).max; // Set unreachable minimum output

        principalToken.approve(address(zap), principal);

        RouterPayload memory swapData = RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_SWAP_CALL_DATA});

        TwoCryptoZap.SwapTokenOutput memory tokenOutput =
            TwoCryptoZap.SwapTokenOutput({tokenRedeemShares: WETH, swapData: swapData});

        vm.expectRevert(Errors.Zap_InsufficientTokenOutput.selector);
        zap.redeemToAnyToken(principalToken, USDC, principal, bob, minAmount, tokenOutput);

        vm.stopPrank();
    }
}
