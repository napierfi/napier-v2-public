// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {VaultInfoResolver} from "./VaultInfoResolver.sol";
import {Errors} from "../../Errors.sol";

/// @notice VaultInfoResolver for assets with external price feeds.
/// @dev This resolver works with price feeds that return prices with 18 decimal places.
contract ExternalPriceResolver is VaultInfoResolver {
    address immutable i_vault;
    address immutable i_asset;
    uint8 immutable i_assetDecimals;
    uint8 immutable i_decimals;
    address immutable i_priceFeed;
    bytes4 immutable i_getPriceFn;
    uint256 immutable i_offset;

    constructor(address vault, address _asset, address priceFeed, bytes4 getPriceFn) {
        i_vault = vault;
        i_asset = _asset;
        i_assetDecimals = ERC20(_asset).decimals();
        i_decimals = ERC20(vault).decimals();
        i_priceFeed = priceFeed;
        i_getPriceFn = getPriceFn;
        i_offset = 10 ** (18 - i_decimals);
    }

    function scale() public view override returns (uint256) {
        // Call the external price feed contract to get the latest price
        (bool success, bytes memory data) = i_priceFeed.staticcall(abi.encodeWithSelector(i_getPriceFn));
        if (!success) revert Errors.Resolver_ConversionFailed();
        uint256 price = abi.decode(data, (uint256));
        // Note on calculation:
        // The price from the external feed should be expressed in the asset's decimal precision (i_assetDecimals).
        // We multiply it by i_offset to adjust for the difference between 18 and the vault's decimals.
        // i_offset = 10 ** (18 - i_decimals)
        // This ensures the final scale is in the format: 10 ** (18 + u - t)
        // Where 'u' is underlying asset decimals and 't' is target (vault) decimals.
        // For example: if shares * price * offset / 1e18 is the conversion to principal,
        // then price must be in the asset's decimal precision to get the correct result.
        return price * i_offset;
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
        return "ExternalPriceResolver";
    }
}
