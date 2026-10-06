// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ITokiHook} from "./ITokiHook.sol";

/// @title Hooklet
/// @notice Hooklets let developers execute custom logic before/after Napier operations.
/// Each TokiPool can have one hooklet attached to it. The least significant bits of the hooklet's
/// address is used to flag which hooklet functions should be called.
///
/// @dev Integration notes: Hooklets MUST NOT mutate pool balances during operations.
///
/// @dev RESTRICTION - Pool Balance Modifications Are PROHIBITED:
/// Hooklets MUST NOT modify pool balances during any operation, especially beforeSwap().
/// This includes but is not limited to:
/// - Donating tokens to the rehypothecation vaults
/// - Any action that changes the vault share price
///
/// WHY THIS RESTRICTION EXISTS:
/// The router pre-calculates swap amounts based on current pool state. If beforeSwap()
/// modifies pool balances, the pre-calculated amounts become stale, causing actual swap
/// outputs to differ from estimates. This results in surplus tokens being trapped in the
/// router contract, creating a poor user experience and potential fund loss.
///
/// CONSEQUENCES OF VIOLATING THIS RESTRICTION:
/// - YT_SWAP_UNDERLYING_FOR_YT: Surplus underlying tokens trapped in router
/// - YT_SWAP_YT_FOR_UNDERLYING: Incorrect payout calculations, surplus trapped
/// - Users must manually SWEEP to recover their funds
interface IHooklet {
    /// @notice Called before a hook transfer operation.
    /// @param sender The address that initiated the transfer.
    /// @param key The Uniswap v4 pool's key.
    /// @param from The address that is sending the tokens.
    /// @param to The address that is receiving the tokens.
    /// @param amount The amount of tokens being transferred.
    /// @return selector IHooklet.beforeTransfer.selector if the call was successful.
    function beforeTransfer(address sender, PoolKey calldata key, address from, address to, uint256 amount)
        external
        returns (bytes4 selector);

    /// @notice Called after a hook transfer operation.
    /// @param sender The address that initiated the transfer.
    /// @param key The Uniswap v4 pool's key.
    /// @param from The address that is sending the tokens.
    /// @param to The address that is receiving the tokens.
    /// @param amount The amount of tokens being transferred.
    /// @return selector IHooklet.afterTransfer.selector if the call was successful.
    function afterTransfer(address sender, PoolKey calldata key, address from, address to, uint256 amount)
        external
        returns (bytes4 selector);

    /// @notice Called before a pool is initialized.
    /// @param sender The address of the account that initiated the initialization.
    /// @param params The initialization's input parameters.
    /// @return selector IHooklet.beforeInitialize.selector if the call was successful.
    function beforeInitialize(address sender, ITokiHook.TokiPoolDeploymentParams calldata params)
        external
        returns (bytes4 selector);

    /// @notice Called after a pool is initialized.
    /// @param sender The address of the account that initiated the initialization.
    /// @param params The initialization's input parameters.
    /// @return selector IHooklet.afterInitialize.selector if the call was successful.
    function afterInitialize(
        address sender,
        PoolKey memory key,
        address liquidityToken,
        ITokiHook.TokiPoolDeploymentParams calldata params
    ) external returns (bytes4 selector);

    /// @notice Called before a deposit operation.
    /// @param sender The address of the account that initiated the deposit.
    /// @param amount0Desired The amount of token0 desired.
    /// @param amount1Desired The amount of token1 desired.
    /// @return selector IHooklet.beforeAddLiquidity.selector if the call was successful.
    function beforeAddLiquidity(address sender, PoolKey calldata key, uint256 amount0Desired, uint256 amount1Desired)
        external
        returns (bytes4 selector);

    /// @notice Called after a deposit operation.
    /// @param sender The address of the account that initiated the deposit.
    /// @param amount0 The amount of token0 deposited.
    /// @param amount1 The amount of token1 deposited.
    /// @return selector IHooklet.afterAddLiquidity.selector if the call was successful.
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        uint256 liquidity,
        uint256 amount0,
        uint256 amount1
    ) external returns (bytes4 selector);

    /// @notice Called before a withdraw operation.
    /// @param sender The address of the account that initiated the withdraw.
    /// @param key The Uniswap v4 pool's key.
    /// @param liquidity The amount of liquidity to withdraw.
    /// @return selector IHooklet.beforeRemoveLiquidity.selector if the call was successful.
    function beforeRemoveLiquidity(address sender, PoolKey calldata key, uint256 liquidity)
        external
        returns (bytes4 selector);

    /// @notice Called after a withdraw operation.
    /// @param sender The address of the account that initiated the withdraw.
    /// @param key The Uniswap v4 pool's key.
    /// @return selector IHooklet.afterRemoveLiquidity.selector if the call was successful.
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        uint256 liquidity,
        uint256 amount0,
        uint256 amount1
    ) external returns (bytes4 selector);

    /// @notice Called before a swap operation.
    /// @param sender The address of the account that initiated the swap.
    /// @param key The Uniswap v4 pool's key.
    /// @param zeroForOne IPoolManager.SwapParams.zeroForOne
    /// @param amountSpecified IPoolManager.SwapParams.amountSpecified
    /// @return selector IHooklet.beforeSwap.selector if the call was successful.
    function beforeSwap(address sender, PoolKey calldata key, bool zeroForOne, int256 amountSpecified)
        external
        returns (bytes4 selector);

    /// @notice Called after a swap operation.
    /// @param sender The address of the account that initiated the swap.
    /// @param key The Uniswap v4 pool's key.
    function afterSwap(address sender, PoolKey calldata key, int256 amount0, int256 amount1, uint96 newLnImpliedRate)
        external
        returns (bytes4 selector);
}
