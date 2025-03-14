// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {ERC20} from "solady/src/tokens/ERC20.sol";

abstract contract ITwoCrypto is ERC20 {
    function balances(uint256 i) external view virtual returns (uint256);

    /// @notice Exchange using wrapped native token by default
    /// @param i Index value for the input coin
    /// @param j Index value for the output coin
    /// @param dx Amount of input coin being swapped in
    /// @param min_dy Minimum amount of output coin to receive
    /// @param receiver Address to send the output coin to, defaults to msg.sender
    /// @return Amount of tokens at index j received by the `receiver`
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy, address receiver)
        external
        virtual
        returns (uint256);

    /// @notice Exchange: but user must transfer dx amount of coin[i] tokens to pool first.
    ///         Pool will not call transferFrom and will only check if a surplus of
    ///         coins[i] is greater than or equal to `dx`.
    /// @dev Use-case is to reduce the number of redundant ERC20 token
    ///      transfers in zaps. Primarily for dex-aggregators/arbitrageurs/searchers.
    ///      Note for users: please transfer + exchange_received in 1 tx.
    /// @param i Index value for the input coin
    /// @param j Index value for the output coin
    /// @param dx Amount of input coin being swapped in
    /// @param min_dy Minimum amount of output coin to receive
    /// @param receiver Address to send the output coin to
    /// @return Amount of tokens at index j received by the `receiver`
    function exchange_received(uint256 i, uint256 j, uint256 dx, uint256 min_dy, address receiver)
        external
        virtual
        returns (uint256);

    /// @notice Adds liquidity into the pool.
    /// @param amounts Amounts of each coin to add
    /// @param min_mint_amount Minimum amount of LP to mint
    /// @param receiver Address to send the LP tokens to, defaults to msg.sender
    /// @return Amount of LP tokens received by the `receiver`
    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount, address receiver)
        external
        virtual
        returns (uint256);

    /// @notice This withdrawal method is very safe, does no complex math since
    ///         tokens are withdrawn in balanced proportions. No fees are charged.
    /// @param _amount Amount of LP tokens to burn
    /// @param min_amounts Minimum amounts of tokens to withdraw
    /// @param receiver Address to send the withdrawn tokens to
    /// @return Amounts of pool tokens received by the `receiver`
    function remove_liquidity(uint256 _amount, uint256[2] calldata min_amounts, address receiver)
        external
        virtual
        returns (uint256[2] memory);

    /// @notice Withdraw liquidity in a single token.
    ///         Involves fees (lower than swap fees).
    /// @dev This operation also involves an admin fee claim.
    /// @param token_amount Amount of LP tokens to burn
    /// @param i Index of the token to withdraw
    /// @param min_amount Minimum amount of token to withdraw
    /// @param receiver Address to send the withdrawn tokens to
    /// @return Amount of tokens at index i received by the `receiver`
    function remove_liquidity_one_coin(uint256 token_amount, uint256 i, uint256 min_amount, address receiver)
        external
        virtual
        returns (uint256);

    function remove_liquidity_one_coin(uint256 token_amount, uint256 i, uint256 min_amount)
        external
        virtual
        returns (uint256);

    /// @notice Calculate LP tokens minted or to be burned for depositing or removing `amounts` of coins
    /// @dev Includes fee.
    /// @param amounts Amounts of tokens being deposited or withdrawn
    /// @param deposit True if it is a deposit action, False if withdrawn.
    /// @return Amount of LP tokens deposited or withdrawn.
    function calc_token_amount(uint256[2] calldata amounts, bool deposit) external view virtual returns (uint256);

    /// @notice Get amount of coin[j] tokens received for swapping in dx amount of coin[i]
    /// @dev Includes fee.
    /// @param i index of input token. Check pool.coins(i) to get coin address at ith index
    /// @param j index of output token
    /// @param dx amount of input coin[i] tokens
    /// @return Exact amount of output j tokens for dx amount of i input tokens.
    function get_dy(uint256 i, uint256 j, uint256 dx) external view virtual returns (uint256);

    /// @notice Get amount of coin[i] tokens to input for swapping out dy amount of coin[j]
    /// @dev This is an approximate method, and returns estimates close to the input amount. Expensive to call on-chain.
    /// @param i index of input token. Check pool.coins(i) to get coin address at ith index
    /// @param j index of output token
    /// @param dy amount of input coin[j] tokens received
    /// @return Approximate amount of input i tokens to get dy amount of j tokens.
    function get_dx(uint256 i, uint256 j, uint256 dy) external view virtual returns (uint256);

    /// @notice Calculates the current price of the LP token w.r.t coin at the 0th index
    /// @return LP price.
    function lp_price() external view virtual returns (uint256);

    /// @notice Calculates the current virtual price of the pool LP token.
    /// @dev Not to be confused with `self.virtual_price` which is a cached virtual price.
    /// @return Virtual Price.
    function get_virtual_price() external view virtual returns (uint256);

    /// @notice Returns the oracle price of the coin at index `k` w.r.t the coin at index 0.
    /// @dev The oracle is an exponential moving average, with a periodicity determined by `self.ma_time`.
    /// @return Price oracle value of kth coin.
    function price_oracle() external view virtual returns (uint256);

    /// @notice Return coin1 price in terms of coin0.
    /// @return e.g. 1 coin0 (18 decimals) is worth 0.0003 coin1 (18 decimals) -> 3,333e18
    function last_prices() external view virtual returns (uint256);

    /// @notice Returns the oracle value for xcp.
    /// @dev The oracle is an exponential moving average, with a periodicity determined by `self.xcp_ma_time`.
    /// @return Oracle value of xcp.
    function xcp_oracle() external view virtual returns (uint256);

    /// @notice Returns the price scale of the coin at index `k` w.r.t the coin at index 0.
    /// @dev Price scale determines the price band around which liquidity is concentrated.
    /// @return Price scale of coin.
    function price_scale() external view virtual returns (uint256);

    /// @notice Returns the fee charged by the pool at current state.
    /// @dev Not to be confused with the fee charged at liquidity action.
    /// @return fee bps.
    function fee() external view virtual returns (uint256);

    /// @notice Calculates output tokens with fee for withdrawing one coin
    /// @param token_amount LP Token amount to burn
    /// @param i token in which liquidity is withdrawn
    /// @return Amount of ith tokens received for burning token_amount LP tokens.
    function calc_withdraw_one_coin(uint256 token_amount, uint256 i) external view virtual returns (uint256);

    /// @notice Returns the fee charged on the given amounts for add_liquidity.
    /// @param amounts The amounts of coins being added to the pool.
    /// @param xp The current balances of the pool multiplied by coin precisions.
    /// @return Fee charged.
    function calc_token_fee(uint256[] calldata amounts, uint256[] calldata xp)
        external
        view
        virtual
        returns (uint256);

    /// @notice Returns the current pool amplification parameter.
    /// @return A param.
    function A() external view virtual returns (uint256);

    /// @notice Returns the current pool gamma parameter.
    /// @return gamma param.
    function gamma() external view virtual returns (uint256);

    /// @notice Returns the current mid fee
    /// @return mid_fee value.
    function mid_fee() external view virtual returns (uint256);

    /// @notice Returns the current out fee
    /// @return out_fee value.
    function out_fee() external view virtual returns (uint256);

    /// @notice Returns the current fee gamma
    /// @return fee_gamma value.
    function fee_gamma() external view virtual returns (uint256);

    /// @notice Returns the current allowed extra profit
    /// @return allowed_extra_profit value.
    function allowed_extra_profit() external view virtual returns (uint256);

    /// @notice Returns the current adjustment step
    /// @return adjustment_step value.
    function adjustment_step() external view virtual returns (uint256);

    /// @notice Returns the current moving average time in seconds
    /// @dev To get time in seconds, the parameter is multiplied by ln(2).
    /// @return ma_time value.
    function ma_time() external view virtual returns (uint256);

    function coins(uint256 i) external view virtual returns (address);

    function initial_A_gamma() external view virtual returns (uint256);
}
