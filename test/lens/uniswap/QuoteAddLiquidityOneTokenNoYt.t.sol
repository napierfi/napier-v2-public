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

contract QuoteAddLiquidityOneTokenNoYtTest is ZapSwapTest {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    COMPONENT TESTING                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _test_Quote_AssetIn(uint256 amount) internal {
        ApproximationParams memory approxParams;

        // Run simulation - snapshot, execute, revert
        (uint256 liquidity,,) = _simulate(amount, approxParams);

        // Query quoter
        TokiQuoter.PreviewAddLiquidityResult memory result =
            quoter.quoteAddLiquidityOneTokenNoYt(poolKey, Token.wrap(address(base)), amount, approxParams);

        assertEq(result.liquidity, liquidity, "Liquidity should match simulated");
        assertGt(result.spotExchangeRateBefore, 0, "spotExchangeRateBefore");
        assertGt(result.executionExchangeRate, 0, "executionExchangeRate");
    }

    function _simulate(uint256 amount, ApproximationParams memory approxParams)
        internal
        returns (uint256 liquidity, uint256, /* amount0Spent */ uint256 /* amount1Spent */ )
    {
        uint256 snapshot = vm.snapshot();

        // Use the correct 3-command sequence for NoYt functionality
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.VAULT_CONNECTOR_DEPOSIT)),
            bytes1(uint8(Commands.TP_SPLIT_UNDERLYING_TOKEN_LIQUIDITY_NO_YT)),
            bytes1(uint8(Commands.TP_ADD_LIQUIDITY))
        );

        uint256 liquidityBefore = SafeTransferLib.balanceOf(pool, alice);

        bytes[] memory inputs = new bytes[](3);
        // VAULT_CONNECTOR_DEPOSIT: Convert base asset to underlying token
        inputs[0] = abi.encode(target, base, base, amount, ActionConstants.ADDRESS_THIS);
        // TP_SPLIT_UNDERLYING_TOKEN_LIQUIDITY_NO_YT: Split underlying, no YT kept
        inputs[1] = abi.encode(poolKey, ActionConstants.CONTRACT_BALANCE, approxParams);
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

        vm.revertTo(snapshot);

        vm.assume(success);

        liquidity = liquidityAfter - liquidityBefore;
        return (liquidity, 0, 0);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          TESTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_Quote_AssetIn() public {
        uint256 amountDesired = 383421;

        // Deal base token to alice for the simulation
        deal(address(base), alice, amountDesired);

        _test_Quote_AssetIn(amountDesired);
    }

    function testFuzz_Quote_AssetIn(uint256 amountDesired) public {
        amountDesired = bound(amountDesired, 1000, 1000000000000 * bOne);
        deal(address(base), alice, amountDesired);

        _test_Quote_AssetIn(amountDesired);
    }

    function test_RevertWhen_BadPool() public override {
        // Create invalid pool key
        PoolKey memory invalidKey = poolKey;
        invalidKey.fee = 9999; // Invalid fee

        Token underlyingToken = Token.wrap(address(target));
        uint256 amountDesired = 1000 * tOne;

        ApproximationParams memory approxParams; // Default empty params

        vm.expectRevert();
        quoter.quoteAddLiquidityOneTokenNoYt(invalidKey, underlyingToken, amountDesired, approxParams);
    }
}
