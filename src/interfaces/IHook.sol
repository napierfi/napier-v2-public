// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

interface ISupplyHook {
    function onSupply(uint256 shares, uint256 principal, bytes calldata data) external;
}

interface IUniteHook {
    function onUnite(uint256 shares, uint256 principal, bytes calldata data) external;
}

interface IHook is ISupplyHook, IUniteHook {}
