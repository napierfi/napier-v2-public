// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IHooklet} from "../../src/interfaces/IHooklet.sol";
import {ITokiHook} from "../../src/interfaces/ITokiHook.sol";

contract MockHooklet is IHooklet {
    function beforeTransfer(address, PoolKey calldata, address, address, uint256) external pure returns (bytes4) {
        return IHooklet.beforeTransfer.selector;
    }

    function afterTransfer(address, PoolKey calldata, address, address, uint256) external pure returns (bytes4) {
        return IHooklet.afterTransfer.selector;
    }

    function beforeInitialize(address, ITokiHook.TokiPoolDeploymentParams calldata) external pure returns (bytes4) {
        return IHooklet.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey memory, address, ITokiHook.TokiPoolDeploymentParams calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooklet.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, uint256, uint256) external pure returns (bytes4) {
        return IHooklet.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(address, PoolKey calldata, uint256, uint256, uint256) external pure returns (bytes4) {
        return IHooklet.afterAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, uint256) external pure returns (bytes4) {
        return IHooklet.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(address, PoolKey calldata, uint256, uint256, uint256)
        external
        pure
        returns (bytes4)
    {
        return IHooklet.afterRemoveLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata, bool, int256) external pure returns (bytes4) {
        return IHooklet.beforeSwap.selector;
    }

    function afterSwap(address, PoolKey calldata, int256, int256, uint96) external pure returns (bytes4) {
        return IHooklet.afterSwap.selector;
    }
}
