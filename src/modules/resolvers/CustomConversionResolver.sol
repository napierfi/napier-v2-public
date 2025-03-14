// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {VaultInfoResolver} from "./VaultInfoResolver.sol";
import {Errors} from "../../Errors.sol";

/// @notice VaultInfoResolver for assets with custom conversion functions.
/// @dev This resolver is for assets that have a conversion function similar to `EIP4626::convertToAssets(uint256 shares)` but with a potentially different function signature.
/// The `i_convertToAssetsFn(10^_decimals())` should return the amount of assets that corresponds to 1 share.
contract CustomConversionResolver is VaultInfoResolver {
    address immutable i_vault;
    address immutable i_asset;
    uint8 immutable i_assetDecimals;
    uint8 immutable i_decimals;
    bytes4 immutable i_convertToAssetsFn;
    uint256 immutable i_offset;

    constructor(address vault, address _asset, bytes4 convertToAssetsFn) {
        i_vault = vault;
        i_asset = _asset;
        i_assetDecimals = ERC20(_asset).decimals();
        i_decimals = ERC20(vault).decimals();
        i_convertToAssetsFn = convertToAssetsFn;
        i_offset = 10 ** (18 - i_decimals);
    }

    function scale() public view override returns (uint256) {
        (bool success, bytes memory data) =
            i_vault.staticcall(abi.encodeWithSelector(i_convertToAssetsFn, 10 ** decimals()));
        if (!success) revert Errors.Resolver_ConversionFailed();
        return abi.decode(data, (uint256)) * i_offset; // 10**(18 + u - t)
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
        return "CustomConversionResolver";
    }
}
