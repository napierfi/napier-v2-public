// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {TokenReward} from "src/Types.sol";
import {IRewardProxy} from "src/interfaces/IRewardProxy.sol";
import {Errors} from "src/Errors.sol";
import {BaseModule} from "./BaseModule.sol";

/// @dev `collectReward` and `collectRewardFor` are called by a principalToken in the delegate call context.
/// @dev No storage variables are allowed in this contract.
/// @dev The behaviour of args on clone in the delegate call context is undefined.
abstract contract RewardProxyModule is BaseModule, IRewardProxy {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                Regular context functions                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev This function SHOULD be overridden by inheriting contracts and initializers should be added.
    function initialize() public virtual override initializer {
        address[] memory tokens = _rewardTokens(address(this));
        require(tokens.length > 0);
        for (uint256 i = 0; i < tokens.length - 1; i++) {
            if (tokens[i] >= tokens[i + 1]) revert Errors.RewardProxy_InconsistentRewardTokens();
        }
    }

    /// @notice Get the reward tokens. Note The elements must not be duplicated.
    function rewardTokens() external view override returns (address[] memory) {
        return _rewardTokens(address(this));
    }

    /// @notice Rescue ERC20 tokens
    function rescue(address token, address to, uint256 value) external restricted {
        SafeTransferLib.safeTransfer(token, to, value);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*            Delegate call context functions                 */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Collect reward for the principalToken.
    /// @dev Called by PrincipalToken in the delegate call context.
    function collectReward(address rewardProxy) public virtual returns (TokenReward[] memory) {}

    /// @notice Helper function to get the reward tokens for `rewardProxy` instance.
    /// @dev To be overridden to return the reward tokens.
    /// ```
    /// bytes memory arg = LibClone.argsOnClone(rewardProxy);
    /// (, address[] memory rewardTokens) = abi.decode(arg, (address, address[]));
    /// ```
    function _rewardTokens(address rewardProxy) internal view virtual returns (address[] memory);
}
