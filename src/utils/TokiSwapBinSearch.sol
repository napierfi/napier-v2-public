// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PoolKey, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";

import {Factory} from "../Factory.sol";
import {PoolFeeModule} from "../modules/PoolFeeModule.sol";
import {ITokiHook, ImmutableParamsLib, StateLibrary} from "../interfaces/ITokiHook.sol";

import "../Types.sol";
import "../Constants.sol" as Constants;
import {LibExpiry} from "./LibExpiry.sol";
import {FunctionTypeCasts} from "./FunctionTypeCasts.sol";
import {LibApproximation, TokiSwap} from "./LibApproximation.sol";

/// @notice Handles heavy calculations
/// @dev - Keep functions view-only
/// @dev - Integrators is responsible for calling the functions with the correct pool key. This contract doesn't validate pool key.
contract TokiSwapBinSearch {
    using SafeCastLib for *;
    using FunctionTypeCasts for *;

    Factory immutable i_factory;

    constructor(Factory _factory) {
        i_factory = _factory;
    }

    /// @notice Compute parameters for underlying->YT swap using binary search
    function computeUnderlyingForYtSwap(PoolKey calldata key, uint256 amountIn, ApproximationParams calldata approx)
        external
        view
        returns (
            int256 bestUnderlying,
            int256 bestPt,
            uint256 bestSwapFee,
            uint256 bestFeeToCuratorAndProtocol,
            uint256 previewDebt
        )
    {
        (TokiSwap.PoolState memory poolState, TokiSwap.TokiAmmParams memory ammParams) = _buildPoolState(key);

        ITokiHook.ImmutableParams memory immutables =
            ImmutableParamsLib.decodeFor.asImmutableParams()(ITokiHook(address(key.hooks)), key.toId());

        int256 amountSpecified = -amountIn.toInt256();
        (bestUnderlying, bestPt, bestSwapFee, bestFeeToCuratorAndProtocol, previewDebt) =
            LibApproximation.binsearchExactUnderlyingForYt(poolState, immutables, ammParams, approx, amountSpecified);
    }

    /// @notice Compute underlying debt for YT->underlying swap
    /// @dev Extracted from TokiPoolRouter lines 378-393 (Scope 2)
    /// @param key Pool key for the swap
    /// @param amountIn Amount of YT tokens to swap
    /// @return underlyingDebt Amount of underlying needed for the swap
    function computeYtForUnderlyingSwap(PoolKey calldata key, uint256 amountIn)
        external
        view
        returns (int256 underlyingDebt, int256 bestPt, uint256 bestSwapFee, uint256 bestFeeToCuratorAndProtocol)
    {
        (TokiSwap.PoolState memory poolState, TokiSwap.TokiAmmParams memory ammParams) = _buildPoolState(key);

        (underlyingDebt, bestPt, bestSwapFee, bestFeeToCuratorAndProtocol) = TokiSwap.computeSwapExactPrincipal(
            poolState,
            ammParams,
            amountIn.toInt256() // Exact-out swap
        );
    }

    /// @notice Compute optimal PT amount for adding liquidity without YT
    function computeSwapExactPrincipalToAddLiquidity(
        PoolKey calldata key,
        uint256 amount0,
        ApproximationParams calldata approx
    )
        external
        view
        returns (int256 bestUnderlying, int256 bestPt, uint256 bestSwapFee, uint256 bestFeeToCuratorAndProtocol)
    {
        (TokiSwap.PoolState memory poolState, TokiSwap.TokiAmmParams memory ammParams) = _buildPoolState(key);

        (bestUnderlying, bestPt, bestSwapFee, bestFeeToCuratorAndProtocol) = LibApproximation
            .binsearchSwapExactPrincipalToAddLiquidity(
            poolState,
            ammParams,
            approx,
            -amount0.toInt256() // Negative because we're selling underlying to PT
        );
    }

    /// @notice Build pool state for approximation calculations
    function _buildPoolState(PoolKey calldata key)
        internal
        view
        returns (TokiSwap.PoolState memory poolState, TokiSwap.TokiAmmParams memory ammParams)
    {
        ITokiHook hook = ITokiHook(address(key.hooks));
        PoolId id = key.toId();
        ITokiHook.ImmutableParams memory immutables = ImmutableParamsLib.decodeFor.asImmutableParams()(hook, id);

        // Check if pool is expired
        LibExpiry.checkNotExpired(immutables.expiry);

        poolState = TokiSwap.PoolState({
            balances: hook.getTotalBalances(id),
            fees: Uint128x2.wrap(StateLibrary.getFees(hook, id)),
            lnImpliedRate: StateLibrary.getLnImpliedRate(hook, id),
            totalLiquidity: StateLibrary.getLiquidity(hook, id)
        });

        ammParams = TokiSwap.computeAmmParams(
            poolState,
            immutables,
            // Revert if module is not found
            PoolFeeModule(i_factory.moduleFor(Currency.unwrap(key.currency1), POOL_FEE_MODULE_INDEX)).getFeePcts()
        );
    }
}
