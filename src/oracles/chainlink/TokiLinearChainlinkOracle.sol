// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {LibClone} from "solady/src/utils/LibClone.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";

import {PoolKey, Currency} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {Factory} from "../../Factory.sol";
import {IChainlinkCompatibleAggregatorV3} from "./IChainlinkCompatibleAggregatorV3.sol";
import {TokiPoolToken} from "../../tokens/TokiPoolToken.sol";
import {PrincipalToken} from "../../tokens/PrincipalToken.sol";
import {LinearPrice} from "../LinearPrice.sol";

import "../../Constants.sol" as Constants;

/// @notice Linear discount rate oracle for PTs against base asset
/// @dev Returns the current value of 1 PT in terms of the asset token, applying a linear discount rate
/// @dev Post-expiry, returns 1:1 ratio (no discount). Pre-expiry, applies time-based linear discount.
contract TokiLinearChainlinkOracle is IChainlinkCompatibleAggregatorV3, Initializable {
    /// @dev Immutable across all instances of the oracle.
    Factory public immutable i_factory;

    error LinearChainlinkOracle_BadPool();
    error LinearChainlinkOracle_InvalidConfiguration();

    constructor(Factory factory) {
        i_factory = factory;
        _disableInitializers();
    }

    function initialize(bytes calldata /*data*/ ) external initializer {
        (address liquidityToken, address base, address quote, uint256 discountRatePerYearBps) = parseImmutableArgs();

        if (i_factory.s_pools(liquidityToken) == address(0)) {
            revert LinearChainlinkOracle_BadPool();
        }

        PoolKey memory key = _poolKey(liquidityToken);

        /// @dev base must be the PT token
        if (base != Currency.unwrap(key.currency1)) {
            revert LinearChainlinkOracle_InvalidConfiguration();
        }

        /// @dev quote must be the asset token
        if (quote != address(PrincipalToken(Currency.unwrap(key.currency1)).i_asset())) {
            revert LinearChainlinkOracle_InvalidConfiguration();
        }

        uint256 expiry = PrincipalToken(Currency.unwrap(key.currency1)).maturity();
        LinearPrice.validateDiscountRatePerYear(expiry, discountRatePerYearBps);
    }

    /// @return answer PT price in terms of the asset token in 18 decimals (discount rate applied)
    function latestRoundData() public view returns (uint80, int256 answer, uint256, uint256, uint80) {
        (address liquidityToken,,, uint256 discountRatePerYearBps) = parseImmutableArgs();

        PoolKey memory key = _poolKey(liquidityToken);

        uint256 expiry = PrincipalToken(Currency.unwrap(key.currency1)).maturity();

        answer = int256(
            Constants.WAD * (Constants.BASIS_POINTS - LinearPrice.getDiscountBps(expiry, discountRatePerYearBps))
                / Constants.BASIS_POINTS
        );
        return (0, answer, 0, block.timestamp, 0);
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function description() external pure returns (string memory) {
        return "Napier V2 Linear Discount Rate Chainlink Oracle";
    }

    function label() external view returns (bytes32) {
        return "TokiLinearChainlinkOracle";
    }

    function parseImmutableArgs()
        public
        view
        returns (address liquidityToken, address base, address quote, uint256 discountRatePerYearBps)
    {
        (liquidityToken, base, quote, discountRatePerYearBps) =
            abi.decode(LibClone.argsOnClone(address(this)), (address, address, address, uint256));
    }

    function _poolKey(address liquidityToken) internal view returns (PoolKey memory) {
        return TokiPoolToken(liquidityToken).i_poolKey();
    }
}
