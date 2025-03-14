// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {ZapForkTest} from "../shared/Fork.t.sol";
import {ITwoCrypto} from "../shared/ITwoCrypto.sol";

import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {TwoCrypto, LibTwoCryptoNG} from "src/utils/LibTwoCryptoNG.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {RouterPayload} from "src/modules/aggregator/AggregationRouter.sol";
import {Errors} from "src/Errors.sol";
import {Token} from "src/Types.sol";
import "src/Constants.sol" as Constants;
import "src/types/Token.sol" as TokenType;

using {TokenType.intoToken} for address;

contract RemoveLiquidityAnyOneTokenTest is ZapForkTest {
    using LibTwoCryptoNG for TwoCrypto;

    /// @dev 1inch payload for swapping 0.850956215 native ETH to USDC
    bytes ONEINCH_PAYLOAD_SWAP_NATIVE_ETH_TO_USDC =
        hex"175accdc000000000000000000000000328809bc894f92807417d2dad6b7c998c1afdac60000000000000000000000000000000000000000000000000000000107f48d3c200000000000000000000000e0554a476a092703abdb3ef35c80e0d76d32939f9432a17f";

    /// @dev 1inch payload for swapping 0.4463796906803165650 native WETH to USDC
    bytes ONEINCH_PAYLOAD_SWAP_NATIVE_WETH_TO_USDC =
        hex"e2c95c820000000000000000000000001d96f2f6bef1202e4ce1ff6dad0c2cb002861d3e000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000000000000000000000000000003df297a2f37d79d200000000000000000000000000000000000000000000000000000002448dab7328000000000000000000000088e6a0c2ddd26feeb64f039a2c41296fcb3f5640fa7a9b25";

    /// @dev 1inch payload for swapping 0.838327764749836201 pufETH to USDC
    bytes ONEINCH_PAYLOAD_SWAP_PUFFER_TO_USDC =
        hex"ea76dddf0000000000000000000000001d96f2f6bef1202e4ce1ff6dad0c2cb002861d3e000000000000000000000000d9a442856c234a39a81a089c06451ebaa4306a720000000000000000000000000000000000000000000000000ba256a90f42dfa9000000000000000000000000000000000000000000000000000000008468bae9280000000000000000000000bf7d01d6cddecb72c2369d1b421967098b10def720000000000000000000000088e6a0c2ddd26feeb64f039a2c41296fcb3f56409432a17f";

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 21069128);
    }

    // alice :>> 0x328809Bc894f92807417D2dAD6b7C998c1aFdac6
    // bob :>> 0x1D96F2f6BeF1202E4Ce1Ff6Dad0c2CB002861d3e
    function setUp() public override {
        super.setUp();

        // Setup initial AMM liquidity
        uint256 assets = 10000 * bOne;
        uint256 shares = 10000 * tOne;

        vm.startPrank(alice);

        deal(address(base), alice, assets);
        base.approve(address(target), assets);
        shares = target.deposit(assets, alice);
        target.approve(address(principalToken), type(uint256).max);
        uint256 amountPT = principalToken.supply(shares, alice);

        deal(address(base), alice, assets);
        base.approve(address(target), assets);
        shares = target.deposit(assets, alice);

        // LP tokens
        target.approve(twocrypto.unwrap(), type(uint256).max);
        principalToken.approve(twocrypto.unwrap(), type(uint256).max);
        ITwoCrypto(twocrypto.unwrap()).add_liquidity([shares, amountPT], 0, alice);
        vm.stopPrank();

        deal(twocrypto.unwrap(), alice, twocrypto.totalSupply() / 2); // 50% of total supply
    }

    function test_WithdrawUnderlying() public {
        Token token = address(target).intoToken();
        uint256 liquidity = twocrypto.balanceOf(alice) / 10000;

        FeePcts newFeePcts = FeePctsLib.pack(3000, 100, 10, 100, 20);
        setFeePcts(newFeePcts);

        vm.warp(expiry - 1);

        _test_Withdraw(USDC, token, liquidity, ONEINCH_PAYLOAD_SWAP_PUFFER_TO_USDC);
    }

    function test_WithdrawBaseAsset_WhenExpired() public {
        uint256 liquidity = twocrypto.balanceOf(alice) / 2024;

        FeePcts newFeePcts = FeePctsLib.pack(100, 3000, 3083, 2121, 331);
        uint256 timestamp = expiry;

        _test_WithdrawBaseAsset(liquidity, newFeePcts, timestamp, ONEINCH_PAYLOAD_SWAP_NATIVE_WETH_TO_USDC);
    }

    function test_WithdrawBaseAsset_WhenNotExpired() public {
        uint256 liquidity = twocrypto.balanceOf(alice) / 100;

        FeePcts newFeePcts = FeePctsLib.pack(100, 787, 323, 2121, 331);
        uint256 timestamp = block.timestamp + 1000;

        _test_WithdrawBaseAsset(liquidity, newFeePcts, timestamp, ONEINCH_PAYLOAD_SWAP_NATIVE_WETH_TO_USDC);
    }

    function _test_WithdrawBaseAsset(uint256 liquidity, FeePcts feePcts, uint256 timestamp, bytes memory payload)
        internal
    {
        Token token = address(base).intoToken();
        setFeePcts(feePcts);

        vm.warp(timestamp);

        _test_Withdraw(USDC, token, liquidity, payload);
    }

    function _test_Withdraw(Token token, Token tokenRedeemShares, uint256 liquidity, bytes memory payload) internal {
        address caller = alice;
        address receiver = bob;
        uint256 oldLiquidity = twocrypto.balanceOf(caller);
        uint256 oldTokenBalnce = token.isNative() ? receiver.balance : token.erc20().balanceOf(receiver);

        liquidity = bound(liquidity, 0, twocrypto.balanceOf(caller));
        _approve(twocrypto.unwrap(), caller, address(zap), liquidity);

        TwoCryptoZap.RemoveLiquidityOneTokenParams memory params = TwoCryptoZap.RemoveLiquidityOneTokenParams({
            twoCrypto: twocrypto,
            liquidity: liquidity,
            tokenOut: token,
            receiver: receiver,
            amountOutMin: 0,
            deadline: block.timestamp
        });
        RouterPayload memory swapData = RouterPayload({router: ONE_INCH_ROUTER, payload: payload});
        TwoCryptoZap.SwapTokenOutput memory tokenOutput =
            TwoCryptoZap.SwapTokenOutput({tokenRedeemShares: tokenRedeemShares, swapData: swapData});

        // If not expired, only underlying token should be withdrawn
        if (!isExpired()) {
            vm.expectCall({
                callee: twocrypto.unwrap(),
                data: abi.encodeWithSignature(
                    "remove_liquidity_one_coin(uint256,uint256,uint256)", liquidity, Constants.TARGET_INDEX, 0
                )
            });
        }

        vm.prank(caller);
        uint256 amountOut = zap.removeLiquidityAnyOneToken(params, tokenOutput);

        uint256 newTokenBalnce = token.isNative() ? receiver.balance : token.erc20().balanceOf(receiver);
        assertEq(twocrypto.balanceOf(caller), oldLiquidity - liquidity, "liquidity balance");
        assertEq(newTokenBalnce, oldTokenBalnce + amountOut, "token balance");
        assertNoFundLeft();
    }

    function test_RevertWhen_BadToken() public {
        (TwoCryptoZap.RemoveLiquidityOneTokenParams memory params, TwoCryptoZap.SwapTokenOutput memory tokenOutput) =
            toyParams();
        params.tokenOut = address(0xcafe).intoToken();

        _approve(twocrypto.unwrap(), alice, address(zap), params.liquidity);

        vm.expectRevert();
        vm.prank(alice);
        zap.removeLiquidityAnyOneToken(params, tokenOutput);
    }

    function test_RevertWhen_SlippageTooLarge_InsufficientTokenOut() public {
        (TwoCryptoZap.RemoveLiquidityOneTokenParams memory params, TwoCryptoZap.SwapTokenOutput memory tokenOutput) =
            toyParams();

        _approve(twocrypto.unwrap(), alice, address(zap), params.liquidity);

        params.amountOutMin = 10000e18;
        vm.expectRevert(Errors.Zap_InsufficientTokenOutput.selector);
        vm.prank(alice);
        zap.removeLiquidityAnyOneToken(params, tokenOutput);
    }

    function test_RevertWhen_TransactionTooOld() public {
        (TwoCryptoZap.RemoveLiquidityOneTokenParams memory params, TwoCryptoZap.SwapTokenOutput memory tokenOutput) =
            toyParams();
        params.deadline = block.timestamp - 1;

        vm.expectRevert(Errors.Zap_TransactionTooOld.selector);
        zap.removeLiquidityAnyOneToken(params, tokenOutput);
    }

    function toyParams()
        internal
        view
        returns (
            TwoCryptoZap.RemoveLiquidityOneTokenParams memory params,
            TwoCryptoZap.SwapTokenOutput memory tokenOutput
        )
    {
        params = TwoCryptoZap.RemoveLiquidityOneTokenParams({
            twoCrypto: twocrypto,
            tokenOut: USDC,
            liquidity: 1e18,
            receiver: alice,
            amountOutMin: 0,
            deadline: block.timestamp
        });

        RouterPayload memory swapData =
            RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_PAYLOAD_SWAP_NATIVE_ETH_TO_USDC});
        tokenOutput = TwoCryptoZap.SwapTokenOutput({tokenRedeemShares: NATIVE_ETH.intoToken(), swapData: swapData});
    }
}
