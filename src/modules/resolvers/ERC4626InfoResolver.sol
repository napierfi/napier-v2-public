// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";
import {VaultInfoResolver} from "./VaultInfoResolver.sol";

/// @notice VaultInfoResolver for ERC4626 underlying assets.
/// @dev Key design decisions:
/// We assume decimals are immutable and should be fetched on runtime instead of being passed as constructor arguments.
/// Resolver should store decimals of asset and vault as immutable variables to save 1 SLOAD on every call from PrincipalToken.
contract ERC4626InfoResolver is VaultInfoResolver {
    address immutable i_vault;
    address immutable i_asset;
    uint8 immutable i_assetDecimals;
    uint8 immutable i_decimals;
    uint256 immutable i_offset;

    constructor(ERC4626 vault) {
        i_vault = address(vault);
        i_asset = vault.asset();
        i_assetDecimals = ERC20(i_asset).decimals();
        i_decimals = vault.decimals();
        i_offset = 10 ** (18 - i_decimals);
    }

    function scale() public view override returns (uint256) {
        return ERC4626(target()).convertToAssets(10 ** decimals()) * i_offset;
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
        return "ERC4626InfoResolver";
    }
}
