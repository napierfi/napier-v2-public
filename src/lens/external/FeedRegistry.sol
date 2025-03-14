// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

/// @notice A currency type.
/// @dev This is a wrapper around an address to allow for type safety.
/// e.g USD is address(840)
type Currency is address;

using {unwrap} for Currency global;
using {eq} for Currency global;

function unwrap(Currency currency) pure returns (address) {
    return Currency.unwrap(currency);
}

function eq(Currency a, address b) pure returns (bool) {
    return Currency.unwrap(a) == b;
}

/// @notice Interface for the Chainlink Feed Registry
interface FeedRegistry {
    function decimals(Currency base, Currency quote) external view returns (uint8);
    function latestRoundData(Currency base, Currency quote)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
