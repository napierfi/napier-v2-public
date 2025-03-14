// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";

import "../Types.sol";
import {IERC4626Wrapper} from "./IERC4626Wrapper.sol";

/// @dev This is a standard implementation for ERC4626 wrappers meant to be deployed via clone with immutable args:
abstract contract StandardERC4626Wrapper is ERC4626, IERC4626Wrapper {
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
    function asset() public view virtual override returns (address);

    /// @inheritdoc IERC4626Wrapper
    function vault() public view virtual returns (address);

    /// @dev Override this function in the derived contract if the underlying vault is not ERC20 standard.
    function name() public view virtual override returns (string memory) {
        return string.concat("Napier ERC4626 Wrapper: ", ERC20(vault()).name());
    }

    /// @dev Override this function in the derived contract if the underlying vault is not ERC20 standard.
    function symbol() public view virtual override returns (string memory) {
        return string.concat("nw-", ERC20(vault()).symbol());
    }
}
