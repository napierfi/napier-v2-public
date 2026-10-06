// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {LibClone} from "solady/src/utils/LibClone.sol";
import {IWrapper} from "../../wrapper/IWrapper.sol";
import {PrincipalToken} from "../../tokens/PrincipalToken.sol";
import {RewardProxyModule} from "../RewardProxyModule.sol";

import "../../Types.sol";
import "../../Errors.sol";

/// @title WrapperRewardProxy
/// @notice A module that claims rewards from Wrapper on behalf of PrincipalToken
/// @dev This module is called via delegate call by PrincipalToken to claim rewards from Wrapper
/// @dev ABI-encoded custom args: `(address[] rewardTokens)`
contract WrapperRewardProxy is RewardProxyModule {
    function initialize() public override initializer {
        (address[] memory tokens,) = _getCustomArgs(address(this));

        // Tokens must be sorted in ascending order for consistent reward handling
        require(tokens.length > 0, "WrapperRewardProxy: no reward tokens");
        for (uint256 i = 1; i < tokens.length; i++) {
            if (tokens[i - 1] >= tokens[i]) revert Errors.RewardProxy_InconsistentRewardTokens();
        }
    }

    /// @notice Claims rewards from Wrapper
    /// @dev Called by PrincipalToken via delegate call
    /// @dev The wrapper will send rewards directly to PrincipalToken
    function collectReward(address rewardProxy) public override returns (TokenReward[] memory) {
        (, address principalToken) = _getCustomArgs(rewardProxy);
        // Get the wrapper address and claim rewards
        try IWrapper(PrincipalToken(principalToken).underlying()).claimRewards() returns (TokenReward[] memory rewards)
        {
            return rewards;
        } catch {
            return new TokenReward[](0);
        }
    }

    /// @notice Returns the list of reward tokens this proxy handles
    function _rewardTokens(address rewardProxy) internal view override returns (address[] memory rewardTokens) {
        (rewardTokens,) = _getCustomArgs(rewardProxy);
    }

    /// @notice Decodes the custom arguments from the proxy's immutable args
    /// @dev Format: abi.encode(principalToken, abi.encode(rewardTokens))
    function _getCustomArgs(address rewardProxy)
        internal
        view
        returns (address[] memory rewardTokens, address principalToken)
    {
        bytes memory args = LibClone.argsOnClone(rewardProxy);
        bytes memory customArgs;
        (principalToken, customArgs) = abi.decode(args, (address, bytes));
        rewardTokens = abi.decode(customArgs, (address[]));
    }

    /// @notice Returns the reward tokens configured for this proxy
    function getCustomArgs() external view returns (address[] memory rewardTokens) {
        (rewardTokens,) = _getCustomArgs(address(this));
    }

    function VERSION() external pure override returns (bytes32) {
        return "2.0.0";
    }
}
