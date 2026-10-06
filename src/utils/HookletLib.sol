// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {LibCall} from "solady/src/utils/LibCall.sol";

import {IHooklet} from "../interfaces/IHooklet.sol";
import {ITokiHook} from "../interfaces/ITokiHook.sol";
import {CustomRevert} from "./CustomRevert.sol";

/// @dev Adapted from Uniswap v4's Hooks.sol
library HookletLib {
    using CustomRevert for bytes4;
    using HookletLib for IHooklet;

    uint160 internal constant ALL_FLAGS_MASK = uint160((1 << 10) - 1);
    uint160 internal constant BEFORE_TRANSFER_FLAG = 1 << 9;
    uint160 internal constant AFTER_TRANSFER_FLAG = 1 << 8;
    uint160 internal constant BEFORE_INITIALIZE_FLAG = 1 << 7;
    uint160 internal constant AFTER_INITIALIZE_FLAG = 1 << 6;
    uint160 internal constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 5;
    uint160 internal constant AFTER_ADD_LIQUIDITY_FLAG = 1 << 4;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 3;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_FLAG = 1 << 2;
    uint160 internal constant BEFORE_SWAP_FLAG = 1 << 1;
    uint160 internal constant AFTER_SWAP_FLAG = 1 << 0;

    error HookletLib_InvalidHookletResponse();

    function callHooklet(IHooklet self, bytes4 selector, bytes memory data) internal returns (bytes memory result) {
        result = LibCall.callContract(address(self), data);
        if (bytes4(result) != selector) HookletLib_InvalidHookletResponse.selector.revertWith();
    }

    modifier noSelfCall(IHooklet self, address sender) {
        if (sender != address(self)) {
            _;
        }
    }

    function hookletBeforeTransfer(
        IHooklet self,
        address sender,
        PoolKey memory key,
        address from,
        address to,
        uint256 amount
    ) internal noSelfCall(self, sender) {
        if (HookletLib.hasPermission(self, BEFORE_TRANSFER_FLAG)) {
            self.callHooklet(
                IHooklet.beforeTransfer.selector,
                abi.encodeCall(IHooklet.beforeTransfer, (sender, key, from, to, amount))
            );
        }
    }

    function hookletAfterTransfer(
        IHooklet self,
        address sender,
        PoolKey memory key,
        address from,
        address to,
        uint256 amount
    ) internal noSelfCall(self, sender) {
        if (HookletLib.hasPermission(self, AFTER_TRANSFER_FLAG)) {
            self.callHooklet(
                IHooklet.afterTransfer.selector, abi.encodeCall(IHooklet.afterTransfer, (sender, key, from, to, amount))
            );
        }
    }

    /// @param sender The address of the deployer. It's always TokiPoolDeployer contract.
    function hookletBeforeInitialize(IHooklet self, address sender, ITokiHook.TokiPoolDeploymentParams calldata params)
        internal
        noSelfCall(self, sender)
    {
        if (self.hasPermission(BEFORE_INITIALIZE_FLAG)) {
            self.callHooklet(
                IHooklet.beforeInitialize.selector, abi.encodeCall(IHooklet.beforeInitialize, (sender, params))
            );
        }
    }

    /// @param sender The address of the deployer. It's always TokiPoolDeployer contract.
    function hookletAfterInitialize(
        IHooklet self,
        address sender,
        PoolKey memory key,
        address liquidityToken,
        ITokiHook.TokiPoolDeploymentParams calldata params
    ) internal noSelfCall(self, sender) {
        if (self.hasPermission(AFTER_INITIALIZE_FLAG)) {
            self.callHooklet(
                IHooklet.afterInitialize.selector,
                abi.encodeCall(IHooklet.afterInitialize, (sender, key, liquidityToken, params))
            );
        }
    }

    /// @param sender The address can be a router.
    function hookletBeforeAddLiquidity(
        IHooklet self,
        address sender,
        PoolKey calldata key,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal noSelfCall(self, sender) {
        if (self.hasPermission(BEFORE_ADD_LIQUIDITY_FLAG)) {
            self.callHooklet(
                IHooklet.beforeAddLiquidity.selector,
                abi.encodeCall(IHooklet.beforeAddLiquidity, (sender, key, amount0Desired, amount1Desired))
            );
        }
    }

    /// @param sender The address can be a router.
    function hookletAfterAddLiquidity(
        IHooklet self,
        address sender,
        PoolKey calldata key,
        uint256 liquidity,
        uint256 amount0,
        uint256 amount1
    ) internal noSelfCall(self, sender) {
        if (self.hasPermission(AFTER_ADD_LIQUIDITY_FLAG)) {
            self.callHooklet(
                IHooklet.afterAddLiquidity.selector,
                abi.encodeCall(IHooklet.afterAddLiquidity, (sender, key, liquidity, amount0, amount1))
            );
        }
    }

    /// @param sender The address can be a router.
    function hookletBeforeRemoveLiquidity(IHooklet self, address sender, PoolKey calldata key, uint256 liquidity)
        internal
        noSelfCall(self, sender)
    {
        if (self.hasPermission(BEFORE_REMOVE_LIQUIDITY_FLAG)) {
            self.callHooklet(
                IHooklet.beforeRemoveLiquidity.selector,
                abi.encodeCall(IHooklet.beforeRemoveLiquidity, (sender, key, liquidity))
            );
        }
    }

    /// @param sender The address can be a router.
    function hookletAfterRemoveLiquidity(
        IHooklet self,
        address sender,
        PoolKey calldata key,
        uint256 liquidity,
        uint256 amount0,
        uint256 amount1
    ) internal noSelfCall(self, sender) {
        if (self.hasPermission(AFTER_REMOVE_LIQUIDITY_FLAG)) {
            self.callHooklet(
                IHooklet.afterRemoveLiquidity.selector,
                abi.encodeCall(IHooklet.afterRemoveLiquidity, (sender, key, liquidity, amount0, amount1))
            );
        }
    }

    /// @param sender The sender from the point of view of the `PoolManager` contract, which can be a router.
    /// @dev For more details, check the official Uniswap v4 documentation
    function hookletBeforeSwap(
        IHooklet self,
        address sender,
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified
    ) internal noSelfCall(self, sender) {
        if (self.hasPermission(BEFORE_SWAP_FLAG)) {
            self.callHooklet(
                IHooklet.beforeSwap.selector,
                abi.encodeCall(IHooklet.beforeSwap, (sender, key, zeroForOne, amountSpecified))
            );
        }
    }

    /// @param sender The sender from the point of view of the `PoolManager` contract, which can be a router.
    function hookletAfterSwap(
        IHooklet self,
        address sender,
        PoolKey calldata key,
        int256 amount0,
        int256 amount1,
        uint96 newLnImpliedRate
    ) internal noSelfCall(self, sender) {
        if (self.hasPermission(AFTER_SWAP_FLAG)) {
            self.callHooklet(
                IHooklet.afterSwap.selector,
                abi.encodeCall(IHooklet.afterSwap, (sender, key, amount0, amount1, newLnImpliedRate))
            );
        }
    }

    function hasPermission(IHooklet self, uint160 flag) internal pure returns (bool) {
        return uint160(address(self)) & flag != 0;
    }
}
