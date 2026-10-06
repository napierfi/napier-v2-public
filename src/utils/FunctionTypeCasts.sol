// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ITokiHook} from "../interfaces/ITokiHook.sol";

/// @dev Type-casts to convert functions returning raw (uint) pointers
///      to functions returning memory pointers of specific types.
///
///      Used to get around solc's over-allocation of memory when
///      dynamic return parameters are re-assigned.
///
///      With `viaIR` enabled, calling any of these functions is a noop.
library FunctionTypeCasts {
    /// @dev Function type cast to avoid duplicate declaration/allocation
    ///      of ITokiHook.ImmutableParams return parameter.
    function asImmutableParams(function(address) internal view returns (uint256) fnIn)
        internal
        pure
        returns (function(address) internal view returns (ITokiHook.ImmutableParams memory) fnOut)
    {
        assembly {
            fnOut := fnIn
        }
    }

    function asImmutableParams(function(ITokiHook, PoolId) internal view returns (uint256) fnIn)
        internal
        pure
        returns (function(ITokiHook, PoolId) internal view returns (ITokiHook.ImmutableParams memory) fnOut)
    {
        assembly {
            fnOut := fnIn
        }
    }
}
