// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {TwoCrypto} from "../types/TwoCrypto.sol";

/// @notice Library for interacting with TwoCrypto contracts.
/// @dev These function do not check contract existence.
library LibTwoCryptoNG {
    error TwoCryptoNG_GetDxFailed();
    error TwoCryptoNG_GetDyFailed();
    error TwoCryptoNG_AddLiquidityFailed();
    error TwoCryptoNG_RemoveLiquidityFailed();
    error TwoCryptoNG_RemoveLiquidityOneCoinFailed();
    error TwoCryptoNG_ExchangeReceivedFailed();
    error TwoCryptoNG_CalcTokenAmountFailed();
    error TwoCryptoNG_CalcWithdrawOneCoinFailed();

    uint256 constant COIN0 = 0;
    uint256 constant COIN1 = 1;

    function name(TwoCrypto twoCrypto) internal view returns (string memory) {
        (bool s, bytes memory ret) = twoCrypto.unwrap().staticcall(abi.encodeWithSignature("name()"));
        if (!s) revert();
        return abi.decode(ret, (string));
    }

    function symbol(TwoCrypto twoCrypto) internal view returns (string memory) {
        (bool s, bytes memory ret) = twoCrypto.unwrap().staticcall(abi.encodeWithSignature("symbol()"));
        if (!s) revert();
        return abi.decode(ret, (string));
    }

    function decimals(TwoCrypto twoCrypto) internal view returns (uint8) {
        return ERC20(twoCrypto.unwrap()).decimals();
    }

    /// @dev When it fails, it reverts with OOG.
    /// - The case includes the code is empty, the return data is less than 0x20 or the call is unsuccessful.
    function coins(TwoCrypto twoCrypto, uint256 i) internal view returns (address coin) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x20, i) // Store the `i` argument.
            mstore(0x00, 0xc6610657) // `coins(uint256)`.
            coin :=
                mload(
                    // mload(success ? 0x00 : uint256(-1)) trick for if-else-revert pattern without branching.
                    // If `success` is false, it consumes all gas and reverts with OOG.
                    // In this case 99.99% of the time, the call will succeed.
                    sub(
                        and(
                            // The arguments of `and` are evaluated from right to left.
                            gt(returndatasize(), 0x1f),
                            // We set a small gas limit. It's enough because TwoCryptoNG records the coin address as a immutable variable.
                            staticcall(10000, twoCrypto, 0x1c, 0x24, 0x00, 0x20) // The return value is written to 0x00.
                        ),
                        0x01
                    )
                )
        }
    }

    function balances(TwoCrypto twoCrypto, uint256 i) internal view returns (uint256 result) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x20, i) // Store the `i` argument.
            mstore(0x00, 0x4903b0d1) // `balances(uint256)`.
            if iszero(and(gt(returndatasize(), 0x1f), staticcall(gas(), twoCrypto, 0x1c, 0x24, 0x00, 0x20))) {
                revert(0x00, 0x00)
            }
            result := mload(0x00)
        }
    }

    function get_virtual_price(TwoCrypto twoCrypto) internal view returns (uint256) {
        (bool s, bytes memory ret) = twoCrypto.unwrap().staticcall(abi.encodeWithSignature("get_virtual_price()"));
        if (!s) revert();
        return abi.decode(ret, (uint256));
    }

    function lp_price(TwoCrypto twoCrypto) internal view returns (uint256) {
        (bool s, bytes memory ret) = twoCrypto.unwrap().staticcall(abi.encodeWithSignature("lp_price()"));
        if (!s) revert();
        return abi.decode(ret, (uint256));
    }

    /// @notice Returns the oracle price of the coin at index `k` w.r.t the coin
    ///         at index 0.
    /// @dev The oracle is an exponential moving average, with a periodicity
    ///      determined by `self.ma_time`. The aggregated prices are cached state
    ///      prices (dy/dx) calculated AFTER the latest trade.
    /// @return uint256 Price oracle value of kth coin.
    function price_oracle(TwoCrypto twoCrypto) internal view returns (uint256) {
        (bool s, bytes memory ret) = twoCrypto.unwrap().staticcall(abi.encodeWithSignature("price_oracle()"));
        if (!s) revert();
        return abi.decode(ret, (uint256));
    }

    function last_prices(TwoCrypto twoCrypto) internal view returns (uint256) {
        (bool s, bytes memory ret) = twoCrypto.unwrap().staticcall(abi.encodeWithSignature("last_prices()"));
        if (!s) revert();
        return abi.decode(ret, (uint256));
    }

    /// @notice Get amount of coin[j] tokens received for swapping in dx amount of coin[i]
    /// @dev Includes fee.
    /// @param i index of input token. Check pool.coins(i) to get coin address at ith index
    /// @param j index of output token
    /// @param dx amount of input coin[i] tokens
    /// @return dy Exact amount of output j tokens for dx amount of i input tokens.
    function get_dy(TwoCrypto twoCrypto, uint256 i, uint256 j, uint256 dx) internal view returns (uint256 dy) {
        /// @solidity memory-safe-assembly
        assembly {
            let m := mload(0x40) // Cache the free memory pointer.
            mstore(0x60, dx) // Store the `dx` argument.
            mstore(0x40, j) // Store the `j` argument.
            mstore(0x20, i) // Store the `i` argument.
            mstore(0x00, 0x556d6e9f) // `get_dy(uint256 i, uint256 j, uint256 dx)`.
            if iszero(and(gt(returndatasize(), 0x1f), staticcall(gas(), twoCrypto, 0x1c, 0x64, 0x00, 0x20))) {
                mstore(0x00, 0x8d44e91c) // `TwoCryptoNG_GetDyFailed()`.
                revert(0x1c, 0x04)
            }
            mstore(0x60, 0) // Restore the zero slot to zero.
            mstore(0x40, m) // Restore the free memory pointer.
            dy := mload(0x00)
        }
    }

    /// @notice Get amount of coin[i] tokens to input for swapping out dy amount
    ///         of coin[j]
    /// @dev This is an approximate method, and returns estimates close to the input
    ///      amount. Expensive to call on-chain.
    /// @param i index of input token. Check pool.coins(i) to get coin address at
    ///        ith index
    /// @param j index of output token
    /// @param dy amount of input coin[j] tokens received
    /// @return Approximate amount of input i tokens to get dy amount of j tokens.
    function get_dx(TwoCrypto twoCrypto, uint256 i, uint256 j, uint256 dy) internal view returns (uint256) {
        (bool s, bytes memory ret) = twoCrypto.unwrap().staticcall(
            abi.encodeWithSelector(
                0x37ed3a7a, // get_dx(uint256 i, uint256 j, uint256 dy) external view returns (uint256)
                i,
                j,
                dy
            )
        );
        if (!s) revert TwoCryptoNG_GetDxFailed();
        return abi.decode(ret, (uint256));
    }

    function balanceOf(TwoCrypto twoCrypto, address account) internal view returns (uint256) {
        return SafeTransferLib.balanceOf(twoCrypto.unwrap(), account);
    }

    function totalSupply(TwoCrypto twoCrypto) internal view returns (uint256 result) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, 0x18160ddd) // `totalSupply()`.
            if iszero(and(gt(returndatasize(), 0x1f), staticcall(gas(), twoCrypto, 0x1c, 0x04, 0x00, 0x20))) {
                revert(0x00, 0x00)
            }
            result := mload(0x00)
        }
    }

    function approve(TwoCrypto twoCrypto, address to, uint256 amount) internal returns (bool) {
        SafeTransferLib.safeApprove(twoCrypto.unwrap(), to, amount);
        return true;
    }

    function add_liquidity(
        TwoCrypto twoCrypto,
        uint256 amount0,
        uint256 amount1,
        uint256 minLiquidity,
        address receiver
    ) internal returns (uint256 liquidity) {
        /// @solidity memory-safe-assembly
        assembly {
            let m := mload(0x40)

            mstore(m, 0x0c3e4b54) // `add_liquidity(uint256[2] amounts, uint256 min_mint_amount, address receiver)`.
            mstore(add(m, 0x20), amount0)
            mstore(add(m, 0x40), amount1)
            mstore(add(m, 0x60), minLiquidity)
            mstore(add(m, 0x80), and(shr(96, not(0)), receiver))
            if iszero(and(gt(returndatasize(), 0x1f), call(gas(), twoCrypto, 0, add(m, 0x1c), 0x84, 0x00, 0x20))) {
                mstore(0x00, 0x1a7e9f6b) // `TwoCryptoNG_AddLiquidityFailed()`.
                revert(0x1c, 0x04)
            }
            liquidity := mload(0x00)
        }
    }

    function remove_liquidity(
        TwoCrypto twoCrypto,
        uint256 liquidity,
        uint256 minAmount0,
        uint256 minAmount1,
        address receiver
    ) internal returns (uint256, uint256) {
        (bool s, bytes memory ret) = twoCrypto.unwrap().call(
            abi.encodeWithSelector(
                0x3eb1719f, // remove_liquidity(uint256 _amount, uint256[2] calldata min_amounts, address receiver)
                liquidity,
                [minAmount0, minAmount1],
                receiver
            )
        );
        if (!s) revert TwoCryptoNG_RemoveLiquidityFailed();
        uint256[2] memory amounts = abi.decode(ret, (uint256[2]));
        return (amounts[0], amounts[1]);
    }

    function remove_liquidity(TwoCrypto twoCrypto, uint256 liquidity, uint256 minAmount0, uint256 minAmount1)
        internal
        returns (uint256, uint256)
    {
        (bool s, bytes memory ret) = twoCrypto.unwrap().call(
            abi.encodeWithSelector(
                0x5b36389c, // remove_liquidity(uint256 _amount, uint256[2] calldata min_amounts)
                liquidity,
                [minAmount0, minAmount1]
            )
        );
        if (!s) revert TwoCryptoNG_RemoveLiquidityFailed();
        uint256[2] memory amounts = abi.decode(ret, (uint256[2]));
        return (amounts[0], amounts[1]);
    }

    function remove_liquidity_one_coin(TwoCrypto twoCrypto, uint256 liquidity, uint256 i, uint256 minAmount)
        internal
        returns (uint256 amountOut)
    {
        (bool s, bytes memory ret) = twoCrypto.unwrap().call(
            abi.encodeWithSelector(
                0xf1dc3cc9, // remove_liquidity_one_coin(uint256 token_amount, uint256 i, uint256 min_amount)
                liquidity,
                i,
                minAmount
            )
        );
        if (!s) revert TwoCryptoNG_RemoveLiquidityOneCoinFailed();
        amountOut = abi.decode(ret, (uint256));
    }

    function exchange_received(TwoCrypto twoCrypto, uint256 i, uint256 j, uint256 dx, uint256 minDy)
        internal
        returns (uint256 dy)
    {
        /// @solidity memory-safe-assembly
        assembly {
            let m := mload(0x40)

            mstore(m, 0x29b244bb) // `exchange_received(uint256,uint256,uint256,uint256)`.
            mstore(add(m, 0x20), i)
            mstore(add(m, 0x40), j)
            mstore(add(m, 0x60), dx)
            mstore(add(m, 0x80), minDy)
            if iszero(and(gt(returndatasize(), 0x1f), call(gas(), twoCrypto, 0, add(m, 0x1c), 0x84, 0x00, 0x20))) {
                mstore(0x00, 0xcd3a66e6) // `TwoCryptoNG_ExchangeReceivedFailed()`.
                revert(0x1c, 0x04)
            }
            dy := mload(0x00)
        }
    }

    function exchange_received(TwoCrypto twoCrypto, uint256 i, uint256 j, uint256 dx, uint256 minDy, address receiver)
        internal
        returns (uint256 dy)
    {
        /// @solidity memory-safe-assembly
        assembly {
            let m := mload(0x40)

            mstore(m, 0x767691e7) // `exchange_received(uint256,uint256,uint256,uint256,address)`.
            mstore(add(m, 0x20), i)
            mstore(add(m, 0x40), j)
            mstore(add(m, 0x60), dx)
            mstore(add(m, 0x80), minDy)
            mstore(add(m, 0xa0), and(shr(96, not(0)), receiver))
            if iszero(and(gt(returndatasize(), 0x1f), call(gas(), twoCrypto, 0, add(m, 0x1c), 0xa4, 0x00, 0x20))) {
                mstore(0x00, 0xcd3a66e6) // `TwoCryptoNG_ExchangeReceivedFailed()`.
                revert(0x1c, 0x04)
            }
            dy := mload(0x00)
        }
    }

    function calc_token_amount_in(TwoCrypto twoCrypto, uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint256)
    {
        return calc_token_amount(twoCrypto, amount0, amount1, true);
    }

    function calc_token_amount_out(TwoCrypto twoCrypto, uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint256)
    {
        return calc_token_amount(twoCrypto, amount0, amount1, false);
    }

    function calc_token_amount(TwoCrypto twoCrypto, uint256 amount0, uint256 amount1, bool deposit)
        internal
        view
        returns (uint256)
    {
        (bool s, bytes memory ret) = twoCrypto.unwrap().staticcall(
            abi.encodeWithSelector(
                0xed8e84f3, // calc_token_amount(uint256[2] calldata amounts, bool deposit) external view returns (uint256)
                amount0,
                amount1,
                deposit
            )
        );
        if (!s) revert TwoCryptoNG_CalcTokenAmountFailed();
        return abi.decode(ret, (uint256));
    }

    function calc_withdraw_one_coin(TwoCrypto twoCrypto, uint256 liquidity, uint256 i)
        internal
        view
        returns (uint256)
    {
        (bool s, bytes memory ret) = twoCrypto.unwrap().staticcall(
            abi.encodeWithSelector(
                0x4fb08c5e, // calc_withdraw_one_coin(uint256 token_amount, uint256 i) external view returns (uint256)
                liquidity,
                i
            )
        );
        if (!s) revert TwoCryptoNG_CalcWithdrawOneCoinFailed();
        return abi.decode(ret, (uint256));
    }
}
