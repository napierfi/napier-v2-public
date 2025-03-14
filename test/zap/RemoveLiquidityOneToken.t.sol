// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";

import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {TwoCrypto, LibTwoCryptoNG} from "src/utils/LibTwoCryptoNG.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";
import {Token} from "src/Types.sol";
import "src/Constants.sol" as Constants;
import "src/types/Token.sol" as TokenType;

using {TokenType.intoToken} for address;

contract RemoveLiquidityOneTokenTest is TwoCryptoZapAMMTest {
    using LibTwoCryptoNG for TwoCrypto;

    function setUp() public virtual override {
        super.setUp();
        _label();

        // Principal Token should be discounted against underlying token
        uint256 initialPrincipal = 140_000 * tOne;
        uint256 initialShare = 100_000 * tOne;

        // Setup initial AMM liquidity
        setUpAMM(AMMInit({user: makeAddr("bocchi"), share: initialShare, principal: initialPrincipal}));

        deal(twocrypto.unwrap(), alice, twocrypto.totalSupply() / 2); // 50% of total supply
    }

    function test_WithdrawUnderlying() public {
        setUpYield(int256(target.totalSupply() / 2));

        Token token = address(target).intoToken();
        uint256 liquidity = twocrypto.balanceOf(alice) / 100;

        FeePcts newFeePcts = FeePctsLib.pack(3000, 100, 10, 100, 20);
        setFeePcts(newFeePcts);

        vm.warp(expiry - 1);

        _test_Withdraw(alice, bob, token, liquidity);
    }

    function test_WithdrawBaseAsset_WhenExpired() public {
        setUpYield(int256(target.totalSupply() / 3));

        uint256 liquidity = twocrypto.balanceOf(alice) / 21298;

        FeePcts newFeePcts = FeePctsLib.pack(100, 55, 99, 2121, 331);
        uint256 timestamp = expiry;

        _test_WithdrawBaseAsset(liquidity, newFeePcts, timestamp);
    }

    function test_WithdrawBaseAsset_WhenNotExpired() public {
        setUpYield(int256(target.totalSupply() / 4));

        uint256 liquidity = twocrypto.balanceOf(alice) / 100;

        FeePcts newFeePcts = FeePctsLib.pack(100, 55, 99, 2121, 331);
        uint256 timestamp = block.timestamp + 1000;

        _test_WithdrawBaseAsset(liquidity, newFeePcts, timestamp);
    }

    function _test_WithdrawBaseAsset(uint256 liquidity, FeePcts feePcts, uint256 timestamp) internal {
        Token token = address(base).intoToken();
        setFeePcts(feePcts);

        vm.warp(timestamp);

        _test_Withdraw(alice, bob, token, liquidity);
    }

    function testFuzz_Withdraw(
        SetupAMMFuzzInput memory input,
        Token token,
        uint256 liquidity,
        FeePcts newFeePcts,
        uint256 timestamp
    ) public boundSetupAMMFuzzInput(input) fuzzAMMState(input) {
        address caller = alice;
        token = boundToken(token);
        liquidity = bound(liquidity, 0, twocrypto.balanceOf(caller));

        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);

        timestamp = bound(timestamp, block.timestamp, expiry + 365 days);
        vm.warp(timestamp);

        _test_Withdraw(caller, bob, token, liquidity);
    }

    function _test_Withdraw(address caller, address receiver, Token token, uint256 liquidity) internal {
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
        (bool s, bytes memory ret) = address(zap).call(abi.encodeCall(zap.removeLiquidityOneToken, (params)));
        vm.assume(s);
        (uint256 amountOut) = abi.decode(ret, (uint256));

        uint256 newTokenBalnce = token.isNative() ? receiver.balance : token.erc20().balanceOf(receiver);
        assertEq(twocrypto.balanceOf(caller), oldLiquidity - liquidity, "liquidity balance");
        assertEq(newTokenBalnce, oldTokenBalnce + amountOut, "token balance");
        assertNoFundLeft();
    }

    function test_RevertWhen_BadToken() public {
        TwoCryptoZap.RemoveLiquidityOneTokenParams memory params = toyParams();
        params.tokenOut = address(0xcafe).intoToken();

        _approve(twocrypto.unwrap(), alice, address(zap), params.liquidity);

        vm.expectRevert(Errors.ERC4626Connector_InvalidToken.selector);
        vm.prank(alice);
        zap.removeLiquidityOneToken(params);
    }

    function test_RevertWhen_SlippageTooLarge_InsufficientTokenOut() public {
        TwoCryptoZap.RemoveLiquidityOneTokenParams memory params = toyParams();
        params.tokenOut = address(base).intoToken();

        _approve(twocrypto.unwrap(), alice, address(zap), params.liquidity);

        params.amountOutMin = 10000e18;
        vm.expectRevert(Errors.Zap_InsufficientTokenOutput.selector);
        vm.prank(alice);
        zap.removeLiquidityOneToken(params);
    }

    function test_RevertWhen_TransactionTooOld() public {
        TwoCryptoZap.RemoveLiquidityOneTokenParams memory params = toyParams();
        params.deadline = block.timestamp - 1;

        vm.expectRevert(Errors.Zap_TransactionTooOld.selector);
        zap.removeLiquidityOneToken(params);
    }

    function toyParams() internal view returns (TwoCryptoZap.RemoveLiquidityOneTokenParams memory) {
        return TwoCryptoZap.RemoveLiquidityOneTokenParams({
            twoCrypto: twocrypto,
            tokenOut: address(base).intoToken(),
            liquidity: 1e18,
            receiver: alice,
            amountOutMin: 0,
            deadline: block.timestamp
        });
    }
}

contract RemoveLiquidityOneETHTest is RemoveLiquidityOneTokenTest {
    function _deployTokens() internal override {
        _deployWETHVault();
    }

    function validTokenInput() internal view override returns (address[] memory tokens) {
        tokens = new address[](3);
        tokens[0] = address(target);
        tokens[1] = address(base);
        tokens[2] = NATIVE_ETH;
    }

    function test_WithdrawNativeETH() public {
        Token token = NATIVE_ETH.intoToken();
        uint256 value = 10 ether;

        _test_Withdraw(alice, bob, token, value);
    }
}
