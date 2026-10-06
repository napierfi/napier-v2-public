// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @dev CHANGED: Adapted from Uniswap Universal Router's V4 module (https://github.com/Uniswap/universal-router/blob/3663f6db6e2fe121753cd2d899699c2dc75dca86/contracts/modules/uniswap/v4/V4SwapRouter.sol)
/// CHANGES:
/// - Extends custom V4Router (forked from @uniswap/v4-periphery) instead of original Uniswap implementation
/// - Removed UniswapImmutables import (not used in original implementation)

import {Permit2Payments} from "@uniswap/universal-router/contracts/modules/Permit2Payments.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {V4Router} from "./V4Router.sol";

/// @title Router for Uniswap v4 Trades
abstract contract V4SwapRouter is V4Router, Permit2Payments {
    constructor(address _poolManager) V4Router(IPoolManager(_poolManager)) {}

    function _pay(Currency token, address payer, uint256 amount) internal override {
        payOrPermit2Transfer(Currency.unwrap(token), payer, address(poolManager), amount);
    }
}
