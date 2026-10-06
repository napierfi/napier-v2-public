// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Permit2Payments} from "@uniswap/universal-router/contracts/modules/Permit2Payments.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import "../../Constants.sol" as Constants;
import "../../Errors.sol";

/// @title Extends Permit2Payments with utility functions for Napier V2 Zap Modules
abstract contract V4Permit2Payments is Permit2Payments {
    /// @notice function that returns address considered executor of the actions
    /// @dev The other context functions, _msgData and _msgValue, are not supported by this contract
    /// In many contracts this will be the address that calls the initial entry point that calls `_executeActions`
    /// `msg.sender` shouldn't be used, as this will be the v4 pool manager contract that calls `unlockCallback`
    /// If using ReentrancyLock.sol, this function can return _getLocker()
    function msgSender() public view virtual returns (address);

    function payIfNeeded(address token, uint256 amount) internal returns (uint256) {
        bool isNative = token == Constants.NATIVE_ETH || token == address(0);
        if (amount == ActionConstants.CONTRACT_BALANCE) {
            amount = isNative ? address(this).balance : SafeTransferLib.balanceOf(token, address(this));
        } else if (isNative) {
            if (address(this).balance < amount) revert Errors.Zap_InsufficientETH();
        } else {
            // Pull ERC20 tokens from the msgSender to this contract
            payOrPermit2Transfer(token, msgSender(), address(this), amount);
        }
        return amount;
    }
}
