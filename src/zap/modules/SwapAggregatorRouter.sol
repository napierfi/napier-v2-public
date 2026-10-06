// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import "../../Types.sol";
import "../../Errors.sol";
import {CustomRevert} from "../../utils/CustomRevert.sol";
import {AggregationRouter, RouterPayload} from "../../modules/aggregator/AggregationRouter.sol";

import {LibApproval} from "../../utils/LibApproval.sol";
import {NapierV2Immutables} from "./NapierV2Immutables.sol";
import {V4Permit2Payments} from "./V4Permit2Payments.sol";

/// @dev A contract inheriting from this contract MUST implement receive() function to allow receiving ETH from AggregationRouter
abstract contract SwapAggregatorRouter is NapierV2Immutables, V4Permit2Payments, LibApproval {
    using CustomRevert for *;

    /// @notice Execute token swap via third-party aggregator
    /// @dev TRUST ASSUMPTIONS:
    ///      - AggregationRouter contract is secure and validates router whitelist
    ///      - Aggregator will send output tokens directly to receiver as specified
    ///      - Unused input tokens will be refunded to msg.sender (this contract)
    ///      - Third-party aggregators handle their own slippage protection
    function _swapViaAggregator(
        Token tokenIn,
        Token tokenOut,
        uint256 amountIn,
        address receiver,
        RouterPayload calldata data
    ) internal {
        uint256 value;
        uint256 baselineBalance; // Expected contract balance after swap. If we're using CONTRACT_BALANCE, this should be 0.

        if (tokenIn.isNative()) {
            uint256 ethBalance = address(this).balance;
            if (amountIn == ActionConstants.CONTRACT_BALANCE) {
                amountIn = ethBalance;
            } else {
                if (ethBalance < amountIn) Errors.Zap_InsufficientETH.selector.revertWith();
                baselineBalance = ethBalance - amountIn; // Balance after sending amountIn
            }
            value = amountIn;
        } else {
            uint256 tokenBalance = SafeTransferLib.balanceOf(Token.unwrap(tokenIn), address(this));

            if (amountIn == ActionConstants.CONTRACT_BALANCE) {
                amountIn = tokenBalance;
            } else {
                // Record baseline BEFORE transfer. This is what we expect after executing the swap.
                baselineBalance = tokenBalance;
                payOrPermit2Transfer(Token.unwrap(tokenIn), msgSender(), address(this), amountIn);
            }
            approveIfNeeded(Token.unwrap(tokenIn), address(_i_aggregationRouter));
        }

        // TRUST: AggregationRouter validates router whitelist and handles swap execution
        AggregationRouter(_i_aggregationRouter).swap{value: value}(tokenIn, tokenOut, amountIn, receiver, data);

        // Handle refunds of unused input tokens
        // TRUST: AggregationRouter refunds unused tokens to msg.sender (this contract)
        uint256 actualBalance =
            tokenIn.isNative() ? address(this).balance : SafeTransferLib.balanceOf(Token.unwrap(tokenIn), address(this));
        if (actualBalance > baselineBalance) {
            unchecked {
                uint256 refundAmount = actualBalance - baselineBalance;
                if (tokenIn.isNative()) {
                    SafeTransferLib.safeTransferETH(msgSender(), refundAmount);
                } else {
                    SafeTransferLib.safeTransfer(Token.unwrap(tokenIn), msgSender(), refundAmount);
                }
            }
        }
    }
}
