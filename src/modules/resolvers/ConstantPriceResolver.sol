// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {VaultInfoResolver} from "./VaultInfoResolver.sol";
import {Errors} from "../../Errors.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";

/**
 * @title ConstantPriceResolver
 * @notice A resolver that maintains a constant 1:1 exchange rate between shares and base asset tokens
 * @dev This resolver follows the same pattern as SharePriceResolver but with constant 1:1 exchange rate
 */
contract ConstantPriceResolver is VaultInfoResolver {
    address immutable i_vault;
    address immutable i_asset;
    uint8 immutable i_assetDecimals;
    uint8 immutable i_decimals;
    uint256 immutable i_scale;
    /**
     * @notice Constructor to set the vault and asset information
     * @param vault The address of the vault token
     * @param _asset The address of the underlying asset
     */

    constructor(address vault, address _asset) {
        if (vault == address(0)) revert Errors.Resolver_ZeroAddress();
        if (_asset == address(0)) revert Errors.Resolver_ZeroAddress();

        i_vault = vault;
        i_asset = _asset;
        i_assetDecimals = ERC20(_asset).decimals();
        i_decimals = ERC20(vault).decimals();

        if (i_decimals > 18 + i_assetDecimals) revert Errors.Resolver_InvalidDecimals();

        i_scale = 10 ** (18 + i_assetDecimals - i_decimals);
    }

    /**
     * @notice Returns the scale factor for the vault with constant 1:1 exchange rate
     * @return The scale factor considering decimals
     */
    function scale() public view override returns (uint256) {
        return i_scale;
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
        return "ConstantPriceResolver";
    }
}
