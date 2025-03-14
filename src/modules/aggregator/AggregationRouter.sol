// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {Token} from "../../types/Token.sol";
import {Errors} from "../../Errors.sol";

import {AccessManaged, AccessManager} from "../AccessManager.sol";
import {LibApproval} from "../../utils/LibApproval.sol";

/// @notice Third-party aggregator payload for swap
/// @param router The address of the router
/// @param payload The payload to call the router
struct RouterPayload {
    address router;
    bytes payload;
}

/**
 * @title AggregationRouter
 * @notice Contract that handles token swaps through various DEX aggregators
 * @dev This contract makes three important assumptions:
 * 1. Deadline and slippage checks are handled by the underlying swap provider in their payload
 * 2. When this swap is the first operation in a sequence (e.g. in Zap),
 *    the input amount will be fully consumed by the swap.
 * 3. Offchain will call API like 1inch set receiver in calldata so Aggregator like 1inch directly transfer the token to receiver
 */
contract AggregationRouter is LibApproval, AccessManaged {
    AccessManager private immutable _i_accessManager;

    mapping(address router => bool isSupported) public s_routers;

    constructor(AccessManager accessManager, address[] memory _routers) {
        _i_accessManager = accessManager;
        for (uint256 i = 0; i < _routers.length; i++) {
            s_routers[_routers[i]] = true;
        }
    }

    function addRouter(address router) external restricted {
        s_routers[router] = true;
    }

    function removeRouter(address router) external restricted {
        s_routers[router] = false;
    }

    function swap(Token tokenIn, Token tokenOut, uint256 amountIn, address receiver, RouterPayload calldata data)
        external
        payable
        returns (uint256 returnAmount)
    {
        address router = data.router;
        if (!s_routers[router]) revert Errors.AggregationRouter_UnsupportedRouter();
        if (tokenIn.isNative() && msg.value < amountIn) revert Errors.AggregationRouter_InvalidMsgValue();

        uint256 balanceBefore =
            tokenOut.isNative() ? receiver.balance : SafeTransferLib.balanceOf(tokenOut.unwrap(), receiver);
        uint256 inputBalanceBefore;

        if (tokenIn.isNative()) {
            // Pre-swap balance
            inputBalanceBefore = address(this).balance - msg.value;
        } else {
            // Pre-swap balance
            inputBalanceBefore = SafeTransferLib.balanceOf(tokenIn.unwrap(), address(this));
            // ERC20 transfer from sender and approve
            SafeTransferLib.safeTransferFrom(tokenIn.unwrap(), msg.sender, address(this), amountIn);
            approveIfNeeded(tokenIn.unwrap(), router);
        }

        (bool success,) = router.call{value: tokenIn.isNative() ? amountIn : 0}(data.payload);
        if (!success) revert Errors.AggregationRouter_SwapFailed();

        uint256 balanceAfter =
            tokenOut.isNative() ? receiver.balance : SafeTransferLib.balanceOf(tokenOut.unwrap(), receiver);
        returnAmount = balanceAfter - balanceBefore;

        /// @audit-info returnAmount can be 0 if data.tokenOut from offchain is different from tokenOut
        if (returnAmount == 0) revert Errors.AggregationRouter_ZeroReturn();

        // Refund post-swap - pre-swap balance
        if (tokenIn.isNative()) {
            uint256 remainingBalance = address(this).balance - inputBalanceBefore;
            if (remainingBalance > 0) {
                SafeTransferLib.safeTransferETH(msg.sender, remainingBalance);
            }
        } else {
            uint256 inputBalanceAfter = SafeTransferLib.balanceOf(tokenIn.unwrap(), address(this));
            uint256 remainingBalance = inputBalanceAfter - inputBalanceBefore;
            if (remainingBalance > 0) {
                SafeTransferLib.safeTransfer(tokenIn.unwrap(), msg.sender, remainingBalance);
            }
        }
    }

    function i_accessManager() public view override returns (AccessManager) {
        return _i_accessManager;
    }

    function rescue(Token token, address to, uint256 value) external restricted {
        if (token.isNative()) {
            SafeTransferLib.safeTransferETH(to, value);
        } else {
            SafeTransferLib.safeTransfer(token.unwrap(), to, value);
        }
    }

    receive() external payable {}
}
