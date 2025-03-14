// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

uint256 constant BASIS_POINTS = 10_000;
uint256 constant WAD = 1e18;
address constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

// Roles
uint256 constant FEE_MANAGER_ROLE = 1 << 0;
uint256 constant FEE_COLLECTOR_ROLE = 1 << 1;
uint256 constant DEV_ROLE = 1 << 2;
uint256 constant PAUSER_ROLE = 1 << 3;
uint256 constant GOVERNANCE_ROLE = 1 << 4;
uint256 constant CONNECTOR_REGISTRY_ROLE = 1 << 5;

// TwoCrypto
uint256 constant TARGET_INDEX = 0;
uint256 constant PT_INDEX = 1;

// Currency
address constant WETH_ETHEREUM_MAINNET = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

// Default fee split ratio (100% to Curator)
uint16 constant DEFAULT_SPLIT_RATIO_BPS = uint16(BASIS_POINTS);
