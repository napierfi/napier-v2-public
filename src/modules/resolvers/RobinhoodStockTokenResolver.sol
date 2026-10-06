// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "solady/src/tokens/ERC20.sol";

import {Errors} from "../../Errors.sol";
import {VaultInfoResolver} from "./VaultInfoResolver.sol";

interface IScaledUIAmount {
    function uiMultiplier() external view returns (uint256);
}

/// @notice Resolves a raw Robinhood Stock Token using its `uiMultiplier()` as the PT/YT scale.
/// @dev Every new multiplier high is accounted as yield, including increases caused by stock splits or corrections.
/// Values at or below the retained high neither reverse previously accrued yield nor create new yield.

contract RobinhoodStockTokenResolver is VaultInfoResolver {
    address immutable i_stockToken;
    uint8 immutable i_decimals;

    constructor(address stockToken) {
        if (stockToken == address(0)) revert Errors.Resolver_ZeroAddress();

        i_stockToken = stockToken;
        i_decimals = ERC20(stockToken).decimals();
        _readScale();
    }

    function scale() public view override returns (uint256) {
        return _readScale();
    }

    function asset() public view override returns (address) {
        return i_stockToken;
    }

    function target() public view override returns (address) {
        return i_stockToken;
    }

    function assetDecimals() public view override returns (uint8) {
        return i_decimals;
    }

    function decimals() public view override returns (uint8) {
        return i_decimals;
    }

    function label() public pure override returns (bytes32) {
        return "RobinhoodStockTokenResolver";
    }

    function _readScale() internal view returns (uint256 multiplier) {
        multiplier = IScaledUIAmount(i_stockToken).uiMultiplier();
        if (multiplier == 0) revert Errors.Resolver_ConversionFailed();
    }
}
