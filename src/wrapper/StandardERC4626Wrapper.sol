// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";

import "../Types.sol";
import {IWrapper} from "./IWrapper.sol";

/// @dev This is a standard implementation for ERC4626 wrappers meant to be deployed via clone with immutable args:
abstract contract StandardERC4626Wrapper is ERC4626, IWrapper {
    /// @dev If needed, implement this function in the derived contract.
    /// @dev `initializer` modifier must be added to this function in the derived contract.
    /// @dev Validate immutable args or run any other initialization logic.
    /// @dev This function must be called as soon as the wrapper is deployed.
    function initialize() external virtual {}

    /// @notice Claims rewards from the underlying tokens.
    /// @dev If needed, implement this function in the derived contract.
    function claimRewards() public virtual returns (TokenReward[] memory) {}

    function decimals() public view virtual override returns (uint8) {
        return ERC20(vault()).decimals() + _decimalsOffset();
    }

    /// @dev The base asset of the original underlying token.
    function asset() public view virtual override(ERC4626, IWrapper) returns (address);

    /// @dev Override this function in the derived contract if the underlying vault is not ERC20 standard.
    function name() public view virtual override returns (string memory) {
        return string.concat("Napier ERC4626 ", ERC20(vault()).name());
    }

    /// @dev Override this function in the derived contract if the underlying vault is not ERC20 standard.
    function symbol() public view virtual override returns (string memory) {
        return string.concat("nw-", ERC20(vault()).symbol());
    }

    function convertToAssets(uint256 shares) public view virtual override(ERC4626, IWrapper) returns (uint256) {
        return ERC4626.convertToAssets(shares);
    }

    function convertToShares(uint256 assets) public view virtual override(ERC4626, IWrapper) returns (uint256) {
        return ERC4626.convertToShares(assets);
    }

    function vault() public view virtual override returns (address);
}
