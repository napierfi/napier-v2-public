// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {LibClone} from "solady/src/utils/LibClone.sol";

import {ContractValidation} from "../../utils/ContractValidation.sol";
import {RewardProxyModule} from "../RewardProxyModule.sol";
import {ISiloIncentivesController} from "../../interfaces/external/ISiloIncentivesController.sol";
import "../../Types.sol";
import "../../Errors.sol";

/// @title SiloRewardProxy
/// @notice A module that claims rewards from Silo Incentives Controller on behalf of PrincipalToken
/// @dev This module is called via delegate call by PrincipalToken to claim rewards from Silo
/// @dev Rewards are distributed linearly to users proportional to their YT holdings, no treasury needed
/// @dev ABI-encoded custom args: `(address[] rewardTokens, address controller, string[] programNames)`
contract SiloRewardProxy is RewardProxyModule {
    function initialize() public override initializer {
        (address[] memory tokens, address controller,) = _getCustomArgs(address(this));

        // Validate params
        if (!ContractValidation.hasCode(controller)) revert Errors.SiloRewardProxy_InvalidController();

        // Tokens must be sorted in ascending order
        require(tokens.length > 0, "SiloRewardProxy: no reward tokens");
        for (uint256 i = 1; i < tokens.length; i++) {
            if (tokens[i - 1] >= tokens[i]) revert Errors.RewardProxy_InconsistentRewardTokens();
        }
    }

    /// @notice Claims rewards from Silo Incentives Controller
    /// @dev Called by PrincipalToken via delegate call
    /// @dev Returns rewards to be distributed linearly to users based on YT holdings
    function collectReward(address rewardProxy) public override returns (TokenReward[] memory) {
        (, address controller, string[] memory programNames) = _getCustomArgs(rewardProxy);

        ISiloIncentivesController.AccruedRewards[] memory accruedRewards;
        if (programNames.length == 0) {
            accruedRewards = ISiloIncentivesController(controller).claimRewards(address(this));
        } else {
            accruedRewards = ISiloIncentivesController(controller).claimRewards(address(this), programNames);
        }
        // Convert AccruedRewards to TokenReward format
        TokenReward[] memory rewards = new TokenReward[](accruedRewards.length);
        for (uint256 i = 0; i < accruedRewards.length; i++) {
            rewards[i] = TokenReward({token: accruedRewards[i].rewardToken, amount: accruedRewards[i].amount});
        }
        return rewards;
    }

    /// @notice Returns the list of reward tokens this proxy handles
    function _rewardTokens(address rewardProxy) internal view override returns (address[] memory rewardTokens) {
        (rewardTokens,,) = _getCustomArgs(rewardProxy);
    }

    /// @notice Decodes the custom arguments from the proxy's immutable args
    /// @dev Format: abi.encode(principalToken, abi.encode(rewardTokens, controller, programNames))
    function _getCustomArgs(address rewardProxy)
        internal
        view
        returns (address[] memory rewardTokens, address controller, string[] memory programNames)
    {
        bytes memory args = LibClone.argsOnClone(rewardProxy);
        bytes memory customArgs;
        (, customArgs) = abi.decode(args, (address, bytes));
        (rewardTokens, controller, programNames) = abi.decode(customArgs, (address[], address, string[]));
    }

    /// @notice Returns the custom arguments configured for this proxy
    function getCustomArgs()
        external
        view
        returns (address[] memory rewardTokens, address controller, string[] memory programNames)
    {
        return _getCustomArgs(address(this));
    }

    function VERSION() external pure override returns (bytes32) {
        return "2.0.0";
    }
}
