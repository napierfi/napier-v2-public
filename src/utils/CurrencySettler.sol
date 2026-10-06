// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

/// @dev Library that encapsulates common PoolManager operation patterns for hooks managing ERC-6909 claim tokens
library CurrencySettler {
    /// @notice Burns ERC-6909 tokens and gets the real tokens from the pool manager
    /// @param poolManager The pool manager instance
    /// @param currency The currency to operate on
    /// @param recipient The address that will receive the underlying tokens
    /// @param amount The amount to burn and take
    function cashOut(IPoolManager poolManager, Currency currency, uint256 amount, address recipient) internal {
        if (amount == 0) return;

        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, recipient, amount);
    }

    /// @notice Transfers tokens from sender to pool manager and mints ERC-6909 tokens
    /// @param payer The address paying the tokens
    function cashIn(IPoolManager poolManager, Currency currency, address payer, uint256 amount) internal {
        _cashIn(poolManager, currency, payer, amount);
    }

    /// @notice Transfers tokens directly from this contract to pool manager and mints ERC-6909 tokens
    function cashIn(IPoolManager poolManager, Currency currency, uint256 amount) internal {
        _cashIn(poolManager, currency, address(this), amount);
    }

    function _cashIn(IPoolManager poolManager, Currency currency, address payer, uint256 amount) private {
        if (amount == 0) return;

        poolManager.sync(currency);
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            if (payer != address(this)) {
                SafeTransferLib.safeTransferFrom(Currency.unwrap(currency), payer, address(poolManager), amount);
            } else {
                SafeTransferLib.safeTransfer(Currency.unwrap(currency), address(poolManager), amount);
            }
            poolManager.settle();
        }

        poolManager.mint(address(this), currency.toId(), amount);
    }
}
