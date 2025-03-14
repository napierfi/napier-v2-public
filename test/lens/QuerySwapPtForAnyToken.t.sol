// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {ZapForkTest} from "../shared/Fork.t.sol";

import {ITwoCrypto} from "../shared/ITwoCrypto.sol";
import "src/Types.sol";
import "src/Constants.sol";

import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {RouterPayload} from "src/modules/aggregator/AggregationRouter.sol";
import {Impersonator} from "src/lens/Impersonator.sol";

contract QuerySwapPtForAnyTokenForkTest is ZapForkTest {
    bytes constant ONEINCH_SWAP_CALL_DATA_USDC_TO_WETH =
        hex"e2c95c82000000000000000000000000000c632910d6be3ef6601420bb35dab2a6f2ede7000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000003b9aca00000000000000000000000000000000000000000000000000053ea141195e6c75288000000000000000000000e0554a476a092703abdb3ef35c80e0d76d32939f9432a17f";

    bytes constant ONEINCH_SWAP_CALL_DATA_WETH_TO_USDC =
        hex"e2c95c8200000000000000000000000098e385f5a7e9bb5fd7a42435d14e63ed8a6570c7000000000000000000000000d9a442856c234a39a81a089c06451ebaa4306a7200000000000000000000000000000000000000000000000006c6589cc7c9306600000000000000000000000000000000000000000000000006d4a65126f3d77c280000000000000000000000bf7d01d6cddecb72c2369d1b421967098b10def79432a17f";

    address public doraemon;

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 20976838);
    }

    function setUp() public virtual override {
        super.setUp();

        // Set up initial liquidity
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

        // Set up impersonator at alice's address
        vm.etch(alice, type(Impersonator).runtimeCode);
        // Set up impersonator at doraemon's address
        doraemon = 0x98E385F5a7E9Bb5Fd7A42435D14e63ed8A6570c7;
        vm.etch(doraemon, type(Impersonator).runtimeCode);
    }

    /// @notice Test querySwapPtForAnyToken function
    function test_QuerySwapPtForAnyToken() public {
        vm.startPrank(doraemon);

        // Get some PT tokens first
        uint256 amountWETH = 1 * 1e18;
        deal(address(base), doraemon, amountWETH);
        base.approve(address(target), amountWETH);
        uint256 shares = target.deposit(amountWETH, doraemon);
        target.approve(address(principalToken), type(uint256).max);
        uint256 amountPT = principalToken.supply(shares, doraemon);

        principalToken.approve(address(zap), amountPT);

        Token tokenOut = WETH;
        Token tokenRedeemShares = Token.wrap(address(target));

        // Run simulation
        Impersonator.QuerySwapPtForAnyTokenParams memory params = Impersonator.QuerySwapPtForAnyTokenParams({
            zap: address(zap),
            quoter: quoter,
            twoCrypto: twocrypto,
            principal: amountPT,
            tokenOut: tokenOut,
            tokenRedeemShares: tokenRedeemShares,
            router: ONE_INCH_ROUTER,
            swapData: ONEINCH_SWAP_CALL_DATA_WETH_TO_USDC
        });

        // Call through alice who has the impersonator code
        uint256 snapshot = vm.snapshot();
        (bool success, bytes memory result) =
            doraemon.call(abi.encodeCall(Impersonator.querySwapPtForAnyToken, (params)));

        require(success, "Simulation failed");
        (uint256 amountOutPreview,, uint256 priceInAssetWei, int256 impliedApyWei) =
            abi.decode(result, (uint256, uint256, uint256, int256));
        vm.revertTo(snapshot);
        // Verify results
        assertGt(amountOutPreview, 0, "Amount out preview should be greater than zero");
        assertGt(priceInAssetWei, 0, "Price in asset should be greater than zero");

        // Execute actual swap for comparison
        TwoCryptoZap.SwapPtParams memory swapParams = TwoCryptoZap.SwapPtParams({
            twoCrypto: twocrypto,
            principal: amountPT,
            tokenOut: tokenOut,
            amountOutMin: 0,
            receiver: doraemon,
            deadline: block.timestamp
        });

        TwoCryptoZap.SwapTokenOutput memory tokenOutput = TwoCryptoZap.SwapTokenOutput({
            tokenRedeemShares: tokenRedeemShares,
            swapData: RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_SWAP_CALL_DATA_WETH_TO_USDC})
        });

        uint256 actualAmountOut = zap.swapPtForAnyToken(swapParams, tokenOutput);

        // Compare simulation with actual result
        assertApproxEqRel(amountOutPreview, actualAmountOut, 0.01e18, "Simulation should be close to actual result");

        // Log results for analysis
        console.log("Amount out preview:", amountOutPreview);
        console.log("Actual amount out:", actualAmountOut);
        console.log("Price in asset (WAD):", priceInAssetWei);
        console.log("Implied APY (WAD):", impliedApyWei);

        vm.stopPrank();
    }
}
