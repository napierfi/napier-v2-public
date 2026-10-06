// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

uint256 constant BASIS_POINTS = 10_000;
uint256 constant WAD = 1e18;
uint32 constant TOKI_SWAP_FEE_SCALE = 100_000_000; // Encodes TokiPool fee parameters with 1e-8 resolution
uint32 constant MAX_TOKI_SWAP_FEE_PARAMS = 9_531_017; // floor(ln(1.10) * TOKI_SWAP_FEE_SCALE)
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

// PoolFeeModule
uint16 constant MAX_RESERVE_FEE_BPS = 10_000; // Max 100% of swap fees that can go to protocol/curator

// Pausable flags
uint16 constant PAUSABLE_LP_SWAPS = 1 << 0;
uint16 constant PAUSABLE_LP_DEPOSITS = 1 << 1;
uint16 constant PAUSABLE_LP_WITHDRAWALS = 1 << 2;
uint16 constant PAUSABLE_LP_TRANSFERS = 1 << 3;
uint16 constant PAUSABLE_CONFIGURATION_UPDATE = 1 << 4;

// Vault flags
uint16 constant REHYPO_VAULT_FROZEN = 1 << 0;
uint16 constant REHYPO_RATIOS_FROZEN = 1 << 1;

// V4 Hooks
// sqrtPriceX96 = floor(sqrt(A / B) * 2 ** 96) where A and B are the currency reserves
uint160 constant CUSTOM_CURVE_INITIAL_SQRT_PRICE = 79228162514264337593543950336;
