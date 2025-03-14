// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {VaultInfoResolver} from "./VaultInfoResolver.sol";
import {Errors} from "../../Errors.sol";

/// @notice VaultInfoResolver for Kind2-like underlying assets.
/// @dev Kind2-like assets have a share price function like `target::assetsPerShare() returns(uint256)` that returns the amount of assets that corresponds to 1 share.
/// `assetsPerShare()` should return the amount of assets that corresponds to 1 share.
contract SharePriceResolver is VaultInfoResolver {
    address immutable i_vault;
    address immutable i_asset;
    uint8 immutable i_assetDecimals;
    uint8 immutable i_decimals;
    bytes4 immutable i_assetsPerShareFn;
    uint256 immutable i_offset;

    constructor(address vault, address _asset, bytes4 assetsPerShareFn) {
        i_vault = vault;
        i_asset = _asset;
        i_assetDecimals = ERC20(_asset).decimals();
        i_decimals = ERC20(vault).decimals();
        i_assetsPerShareFn = assetsPerShareFn;
        i_offset = 10 ** (18 - i_decimals);
    }

    function scale() public view override returns (uint256) {
        (bool success, bytes memory data) = i_vault.staticcall(abi.encodeWithSelector(i_assetsPerShareFn));
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
        return "SharePriceResolver";
    }
}
