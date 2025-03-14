// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {VaultInfoResolver} from "src/modules/resolvers/VaultInfoResolver.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";

contract MockResolver is VaultInfoResolver {
    address immutable i_vault;
    address immutable i_asset;
    uint8 immutable i_assetDecimals;
    uint8 immutable i_decimals;
    uint256 immutable i_offset;

    constructor(address vault) {
        i_vault = vault;
        i_asset = ERC4626(vault).asset();
        i_assetDecimals = ERC20(i_asset).decimals();
        i_decimals = ERC20(vault).decimals();
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
