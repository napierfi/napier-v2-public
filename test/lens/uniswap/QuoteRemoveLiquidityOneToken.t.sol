// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {ZapSwapTest} from "../../zap/uniswap/SwapYT.t.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {TokiQuoter} from "src/lens/uniswap/TokiQuoter.sol";
import {Commands} from "src/zap/uniswap/Commands.sol";

import "src/Types.sol";
import "src/Errors.sol";

/// @notice Pre-expiry tests for TokiQuoter.quoteRemoveLiquidityOneToken
/// Simulate path (commands order):
/// 1) TP_REMOVE_LIQUIDITY → receiver: router (ADDRESS_THIS)
/// 2) V4_SWAP (PT -> underlying) using router balances
/// 3) VAULT_CONNECTOR_REDEEM (target -> base) to alice (MSG_SENDER)
contract QuoteRemoveLiquidityOneToken_BeforeExpiry_Test is ZapSwapTest {
    function _baseToken() internal view returns (Token) {
        return Token.wrap(address(base));
    }

    function _encodeV4SwapInput(IV4Router.ExactInputSingleParams memory params) internal view returns (bytes memory) {
        bytes memory v4Commands = abi.encodePacked(
            bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)), bytes1(uint8(Actions.SETTLE)), bytes1(uint8(Actions.TAKE))
        );

        bytes[] memory v4Inputs = new bytes[](3);
        v4Inputs[0] = abi.encode(params);
        v4Inputs[1] = abi.encode(poolKey.currency1, ActionConstants.CONTRACT_BALANCE, false);
        v4Inputs[2] = abi.encode(poolKey.currency0, ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA);

        return abi.encode(v4Commands, v4Inputs);
    }

    /// @dev Simulate pre-expiry with command order: remove → swap → connector redeem.
    function _simulate(uint256 liquidity) internal returns (uint256 result) {
        _approveZap(alice, pool, type(uint160).max);

        TokiQuoter.QuoteRemoveLiquidityResult memory preview = quoter.quoteRemoveLiquidity(poolKey, liquidity);
        uint256 previewAmount1 = preview.amount1Out;

        IV4Router.ExactInputSingleParams memory swapParams = IV4Router.ExactInputSingleParams({
            poolKey: poolKey,
            zeroForOne: false,
            amountIn: uint128(previewAmount1),
            amountOutMinimum: 0,
            hookData: ""
        });

        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.TP_REMOVE_LIQUIDITY)),
            bytes1(uint8(Commands.V4_SWAP)),
            bytes1(uint8(Commands.VAULT_CONNECTOR_REDEEM))
        );
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(poolKey, liquidity, 0, 0, ActionConstants.ADDRESS_THIS);
        inputs[1] = _encodeV4SwapInput(swapParams);
        inputs[2] = abi.encode(
            address(target), address(base), address(base), ActionConstants.CONTRACT_BALANCE, ActionConstants.MSG_SENDER
        );

        uint256 snap = vm.snapshot();
        uint256 baseBefore = base.balanceOf(alice);

        vm.prank(alice);
        (bool s,) = address(zap).call(abi.encodeWithSignature("execute(bytes,bytes[])", commands, inputs));
        uint256 baseAfter = base.balanceOf(alice);
        result = baseAfter - baseBefore;
        vm.revertTo(snap);

        vm.assume(s);
    }

    function _test_Quote(uint256 liquidity) internal {
        deal(pool, alice, liquidity);

        // Act
        vm.warp(expiry - 1);
        uint256 result = _simulate(liquidity);

        // Assert
        TokiQuoter.QuoteRemoveLiquidityOneTokenResult memory preview =
            quoter.quoteRemoveLiquidityOneToken(poolKey, Token.wrap(address(base)), liquidity);
        assertEq(preview.amountOut, result, "Quoted base out should equal router-simulated amount");
        assertGt(preview.spotExchangeRateBefore, 0, "Spot exchange rate should be not zero");
        assertGt(preview.executionExchangeRate, 0, "Execution exchange rate should be not zero");
        // Price impact could be zero
    }

    function test_Quote() public {
        uint256 liquidity = SafeTransferLib.totalSupply(pool) / 3;
        _test_Quote(liquidity);
    }

    function testFuzz_Quote(uint256 liquidity) public {
        liquidity = bound(liquidity, 0, SafeTransferLib.totalSupply(pool) / 2);
        _test_Quote(liquidity);
    }

    function test_RevertWhen_BadPool() public override {
        PoolKey memory invalidPoolKey = poolKey;
        invalidPoolKey.hooks = IHooks(address(0xdead));

        // Assert
        vm.expectRevert(Errors.BadTokiPool.selector);
        quoter.quoteRemoveLiquidityOneToken(invalidPoolKey, Token.wrap(address(base)), 1000);
    }

    function test_RevertWhen_InvalidToken() public {
        Token unsupported = Token.wrap(address(randomToken));

        // Assert
        vm.expectRevert(); // Should revert on unsupported token
        quoter.quoteRemoveLiquidityOneToken(poolKey, unsupported, 1000);
    }
}

/// @notice Tests for TokiQuoter.quoteRemoveLiquidityOneToken (post-expiry only)
contract QuoteRemoveLiquidityOneToken_AfterExpiry_Test is ZapSwapTest {
    function _simulate(uint256 liquidity) internal returns (uint256 result) {
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.TP_REMOVE_LIQUIDITY)),
            bytes1(uint8(Commands.PT_REDEEM)),
            bytes1(uint8(Commands.VAULT_CONNECTOR_REDEEM)),
            bytes1(uint8(Commands.SWEEP))
        );

        bytes[] memory inputs = new bytes[](4);
        inputs[0] = abi.encode(poolKey, liquidity, 0, 0, ActionConstants.ADDRESS_THIS);
        inputs[1] = abi.encode(principalToken, ActionConstants.CONTRACT_BALANCE, ActionConstants.ADDRESS_THIS);
        inputs[2] = abi.encode(
            address(target), address(base), address(base), ActionConstants.CONTRACT_BALANCE, ActionConstants.MSG_SENDER
        );
        // sweep base to alice
        inputs[3] = abi.encode(address(base), alice, 0);

        uint256 balanceBefore = base.balanceOf(alice);
        uint256 snap = vm.snapshot();

        // Approve LP to router via Permit2
        _approveZap(alice, pool, type(uint160).max);

        vm.prank(alice);
        (bool ok,) = address(zap).call(abi.encodeWithSignature("execute(bytes,bytes[])", commands, inputs));

        uint256 balanceAfter = base.balanceOf(alice);
        vm.revertTo(snap);

        vm.assume(ok);
        result = balanceAfter - balanceBefore;
    }

    function _test_Quote(uint256 liquidity) internal {
        // Arrange
        vm.warp(expiry + 1);

        // Act
        uint256 amoutOut = _simulate(liquidity);

        // Assert
        TokiQuoter.QuoteRemoveLiquidityOneTokenResult memory preview =
            quoter.quoteRemoveLiquidityOneToken(poolKey, Token.wrap(address(base)), liquidity);
        assertEq(preview.amountOut, amoutOut, "Quoted amount should equal simulated after-expiry amount");
        assertEq(preview.spotExchangeRateBefore, 0, "Spot exchange rate should be 0");
        assertEq(preview.executionExchangeRate, 0, "Execution exchange rate should be 0");
        assertEq(preview.priceImpact, 0, "Price impact should be 0");
    }

    function test_Quote() public {
        uint256 totalSupply = SafeTransferLib.totalSupply(pool);
        uint256 liquidity = totalSupply / 313;
        deal(pool, alice, liquidity);
        _test_Quote(liquidity);
    }

    function testFuzz_Quote(uint256 liquidity) public {
        uint256 totalSupply = SafeTransferLib.totalSupply(pool);
        liquidity = bound(liquidity, 0, totalSupply / 2);
        deal(pool, alice, liquidity);
        _test_Quote(liquidity);
    }

    function test_RevertWhen_BadPool() public override {
        PoolKey memory invalidPoolKey = poolKey;
        invalidPoolKey.hooks = IHooks(address(0xdead));

        // Assert
        vm.expectRevert(Errors.BadTokiPool.selector);
        quoter.quoteRemoveLiquidityOneToken(invalidPoolKey, Token.wrap(address(base)), 1000);
    }

    function test_RevertWhen_InvalidToken() public {
        vm.warp(expiry + 1);

        // Pick an unsupported token (neither asset nor ERC4626 nor native)
        Token unsupported = Token.wrap(address(randomToken));

        // Assert
        vm.expectRevert(); // BaseQuoter reverts with connector invalid token / ERC4626 fallback failure
        quoter.quoteRemoveLiquidityOneToken(poolKey, unsupported, 1000);
    }
}
