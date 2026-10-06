// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "solady/src/tokens/ERC20.sol";

import {VaultInfoResolver} from "./VaultInfoResolver.sol";
import {AggregatorV3Interface} from "../../lens/external/AggregatorV3Interface.sol";

import {Errors} from "../../Errors.sol";

/// @notice VaultInfoResolver for assets using Chainlink price feeds
/// @dev This resolver works with Chainlink price feeds to get asset prices
contract ChainlinkResolver is VaultInfoResolver {
    address immutable i_vault;
    address immutable i_asset;
    uint8 immutable i_assetDecimals;
    uint8 immutable i_decimals;
    address immutable i_priceFeed;
    uint256 immutable i_offset;

    constructor(address vault, address _asset, address priceFeed) {
        if (vault == address(0)) revert Errors.Resolver_ZeroAddress();
        if (_asset == address(0)) revert Errors.Resolver_ZeroAddress();
        if (priceFeed == address(0)) revert Errors.Resolver_ZeroAddress();

        i_vault = vault;
        i_asset = _asset;
        i_assetDecimals = ERC20(_asset).decimals();
        i_decimals = ERC20(vault).decimals();
        i_priceFeed = priceFeed;
        i_offset = 10 ** (18 - i_decimals);
    }

    /// @notice Gets the latest price from Chainlink price feed and converts it to the correct scale
    /// @return The scaled price considering decimals
    function scale() public view override returns (uint256) {
        uint8 priceFeedDecimals = AggregatorV3Interface(i_priceFeed).decimals();

        (, int256 price,,,) = AggregatorV3Interface(i_priceFeed).latestRoundData();

        if (price <= 0) revert Errors.Resolver_ConversionFailed();

        uint256 adjustedPrice = uint256(price) * i_offset;

        if (i_assetDecimals > priceFeedDecimals) {
            adjustedPrice = adjustedPrice * 10 ** (i_assetDecimals - priceFeedDecimals);
        } else {
            adjustedPrice = adjustedPrice / 10 ** (priceFeedDecimals - i_assetDecimals);
        }

        return adjustedPrice;
    }

    function asset() public view override returns (address) {
        return i_asset;
    }

    function target() public view override returns (address) {
        return i_vault;
    }

    function assetDecimals() public view override returns (uint8) {
        return i_assetDecimals;
    }

    function decimals() public view override returns (uint8) {
        return i_decimals;
    }

    function label() public pure override returns (bytes32) {
        return "ChainlinkResolver";
    }
}
