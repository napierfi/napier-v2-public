// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

/// @title VaultInfoResolver
/// @notice Abstract contract for resolving vault information.
abstract contract VaultInfoResolver {
    function asset() public view virtual returns (address);
    function target() public view virtual returns (address);
    function scale() public view virtual returns (uint256);
    function assetDecimals() public view virtual returns (uint8);
    function decimals() public view virtual returns (uint8);
    function label() public pure virtual returns (bytes32);
}
