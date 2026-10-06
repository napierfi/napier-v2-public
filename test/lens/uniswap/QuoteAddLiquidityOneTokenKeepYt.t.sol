// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {ZapSwapTest} from "../../zap/uniswap/SwapYT.t.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {TokiQuoter} from "src/lens/uniswap/TokiQuoter.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {PrincipalTokenQuoter} from "src/lens/PrincipalTokenQuoter.sol";
import {Commands} from "src/zap/uniswap/Commands.sol";

import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

contract QuoteAddLiquidityOneTokenKeepYtTest is ZapSwapTest {
    function _test_Quote_AssetIn(uint256 amount) internal {
        // Run simulation - snapshot, execute, revert
        (uint256 liquidity,, uint256 amount1Spent) = _simulate(amount);

        // Query quoter
        TokiQuoter.PreviewAddLiquidityResult memory result =
            quoter.quoteAddLiquidityOneTokenKeepYt(poolKey, Token.wrap(address(base)), amount);

        // Verify results match
        assertEq(result.liquidity, liquidity, "Liquidity should match simulated");
        assertEq(result.amount1Spent, amount1Spent, "Amount1 spent should match simulated");
        assertEq(result.spotExchangeRateBefore, 0, "spotExchangeRateBefore should be zero for KeepYt");
        assertEq(result.executionExchangeRate, 0, "executionExchangeRate should be zero for KeepYt");
        assertEq(result.priceImpact, 0, "priceImpact should be zero for KeepYt");
    }

    function _simulate(uint256 amount)
        internal
        returns (uint256 liquidity, uint256, /* amount0Spent */ uint256 amount1Spent)
    {
        uint256 snapshot = vm.snapshot();

        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.VAULT_CONNECTOR_DEPOSIT)),
            bytes1(uint8(Commands.TP_SPLIT_UNDERLYING_TOKEN_LIQUIDITY_KEEP_YT)),
            bytes1(uint8(Commands.TP_ADD_LIQUIDITY))
        );

        uint256 liquidityBefore = SafeTransferLib.balanceOf(pool, alice);
        uint256 ptSupplyBefore = principalToken.totalSupply();

        bytes[] memory inputs = new bytes[](3);
        // VAULT_CONNECTOR_DEPOSIT: Convert base asset to underlying token
        inputs[0] = abi.encode(target, base, base, amount, ActionConstants.ADDRESS_THIS);
        // TP_SPLIT_UNDERLYING_TOKEN_LIQUIDITY_KEEP_YT: Split underlying, keep YT
        inputs[1] = abi.encode(poolKey, ActionConstants.CONTRACT_BALANCE, ActionConstants.MSG_SENDER);
        // TP_ADD_LIQUIDITY: Add split amounts as liquidity
        inputs[2] = abi.encode(
            poolKey,
            ActionConstants.CONTRACT_BALANCE,
            ActionConstants.CONTRACT_BALANCE,
            0, // min liquidity
            ActionConstants.MSG_SENDER
        );

        // Approve base asset (input token) for permit2
        _approveZap(alice, address(base), uint160(amount));

        vm.prank(alice);
        bytes memory encodedCall = abi.encodeWithSignature("execute(bytes,bytes[])", commands, inputs);
        (bool success,) = address(zap).call(encodedCall);

        uint256 liquidityAfter = SafeTransferLib.balanceOf(pool, alice);
        uint256 ptSupplyAfter = principalToken.totalSupply();

        vm.revertTo(snapshot);

        vm.assume(success);

        liquidity = liquidityAfter - liquidityBefore;
        amount1Spent = ptSupplyAfter - ptSupplyBefore;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          TESTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_Quote_AssetIn() public {
        uint256 amountDesired = 3832181290421;

        // Deal base token to alice for the simulation
        deal(address(base), alice, amountDesired);

        _test_Quote_AssetIn(amountDesired);
    }

    function testFuzz_Quote_AssetIn(uint256 amountDesired) public {
        amountDesired = bound(amountDesired, 0, 1000000000000 * bOne);
        deal(address(base), alice, amountDesired);

        _test_Quote_AssetIn(amountDesired);
    }

    function test_RevertWhen_BadPool() public override {
        // Create invalid pool key
        PoolKey memory invalidKey = poolKey;
        invalidKey.fee = 9999; // Invalid fee

        Token underlyingToken = Token.wrap(address(target));
        uint256 amountDesired = 1000 * tOne;

        vm.expectRevert();
        quoter.quoteAddLiquidityOneTokenKeepYt(invalidKey, underlyingToken, amountDesired);
    }
}
