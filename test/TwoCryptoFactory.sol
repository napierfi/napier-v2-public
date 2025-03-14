// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

interface TwoCryptoFactory {
    /// @notice Deploy a new pool
    /// @param _name Name of the new plain pool
    /// @param _symbol Symbol for the new plain pool - will be concatenated with factory symbol
    /// @param _coins Addresses of the coins in the pool
    /// @param implementation_id ID of the pool implementation
    /// @param A Amplification coefficient
    /// @param gamma Swap fee coefficient
    /// @param mid_fee Fee for stable swaps
    /// @param out_fee Fee for volatile swaps
    /// @param fee_gamma Adjustment coefficient for fees
    /// @param allowed_extra_profit Extra profit limit for adjusting swap fees
    /// @param adjustment_step Step size for fee adjustment
    /// @param ma_exp_time Moving average expiration time
    /// @param initial_price Initial price for the pool
    /// @return Address of the deployed pool
    function deploy_pool(
        string calldata _name,
        string calldata _symbol,
        address[2] calldata _coins,
        uint256 implementation_id,
        uint256 A,
        uint256 gamma,
        uint256 mid_fee,
        uint256 out_fee,
        uint256 fee_gamma,
        uint256 allowed_extra_profit,
        uint256 adjustment_step,
        uint256 ma_exp_time,
        uint256 initial_price
    ) external returns (address);

    /// @notice Set pool implementation
    /// @dev Set to address(0) to prevent deployment of new pools
    /// @param _pool_implementation Address of the new pool implementation
    /// @param _implementation_index Index of the pool implementation
    function set_pool_implementation(address _pool_implementation, uint256 _implementation_index) external;

    /// @notice Set gauge implementation
    /// @dev Set to address(0) to prevent deployment of new gauges
    /// @param _gauge_implementation Address of the new gauge implementation
    function set_gauge_implementation(address _gauge_implementation) external;

    /// @notice Set views contract implementation
    /// @param _views_implementation Address of the new views contract
    function set_views_implementation(address _views_implementation) external;

    /// @notice Set math implementation
    /// @param _math_implementation Address of the new math contract
    function set_math_implementation(address _math_implementation) external;

    function initialise_ownership(address fee_receiver, address admin) external;
}
