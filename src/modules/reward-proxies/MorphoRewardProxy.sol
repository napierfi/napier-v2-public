// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {LibClone} from "solady/src/utils/LibClone.sol";

import {IUniversalRewardsDistributor} from "../../interfaces/external/IUniversalDistributor.sol";
import {RewardProxyModule} from "../RewardProxyModule.sol";

import {ContractValidation} from "../../utils/ContractValidation.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import "../../Types.sol";
import "../../Errors.sol";

/// @dev Namespace has to be used for avoiding storage slot collisions.
/// @dev ABI-encoded custom args: `(address[] rewardTokens, address distributor, address treasury)`
contract MorphoRewardProxy is RewardProxyModule {
    /// @custom:storage-location `keccak256(abi.encode(uint256(keccak256("napier-v2.storage.morpho-reward-proxy")) - 1)) & ~bytes32(uint256(0xff))`
    bytes32 constant MORPHO_REWARD_PROXY_STORAGE_LOCATION =
        0x6c198287b982400fbfc3e3153e2d55da6e1e11d4adb0d957899fb3c9b5925b00;

    struct MorphoRewardProxyStorage {
        /// @notice Total amount claimed so far for each reward token.
        mapping(address rewardToken => uint256) lastClaimed;
    }

    function initialize() public override initializer {
        (address[] memory tokens, address distributor, address treasury) = _getCustomArgs(address(this));

        // Validate params
        if (!ContractValidation.hasCode(distributor)) revert Errors.MorphoRewardProxy_InvalidDistributor();
        if (treasury == address(0)) revert Errors.MorphoRewardProxy_InvalidTreasury();
        // Tokens must be sorted in ascending order
        require(tokens.length > 0);
        for (uint256 i = 0; i < tokens.length - 1; i++) {
            if (tokens[i] >= tokens[i + 1]) revert Errors.RewardProxy_InconsistentRewardTokens();
        }
    }

    /// @dev This function is called by a principalToken in delegate call context.
    /// @dev Don't make a delegate call to an external contract inside this function.
    function collectReward(address rewardProxy) public override returns (TokenReward[] memory) {
        MorphoRewardProxyStorage storage $ = _getStorage();

        (address[] memory rewardTokens, address distributor, address treasury) = _getCustomArgs(rewardProxy);

        TokenReward[] memory tokenRewards = new TokenReward[](0);

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address reward = rewardTokens[i];
            uint256 lastClaimed = $.lastClaimed[reward];

            // Get the amount of reward tokens claimed so far.
            uint256 claimed = IUniversalRewardsDistributor(distributor).claimed({
                account: address(this), // Principal Token in delegate call context
                reward: reward
            });

            // Note: The Distributor allows anyone to claim rewards on behalf of the account.
            // We make an assumption that the someone claims rewards on behalf of the PrincipalToken.
            uint256 collected; // The amount of reward tokens collected since the last claim.
            if (claimed > lastClaimed) {
                $.lastClaimed[reward] = claimed;
                collected = claimed - lastClaimed;
            }

            SafeTransferLib.safeTransfer(reward, treasury, collected);
        }

        return tokenRewards;
    }

    function _rewardTokens(address rewardProxy) internal view override returns (address[] memory rewardTokens) {
        (rewardTokens,,) = _getCustomArgs(rewardProxy);
    }

    /// @notice Decode the custom arguments of the proxy from `immutableArgs = abi.encode(principalToken, customArgs)`.
    /// @dev Internal function for both regular and delegate call context.
    function _getCustomArgs(address rewardProxy)
        internal
        view
        returns (address[] memory rewardTokens, address distributor, address treasury)
    {
        bytes memory args = LibClone.argsOnClone(rewardProxy);
        (, bytes memory customArgs) = abi.decode(args, (address, bytes));
        (rewardTokens, distributor, treasury) = abi.decode(customArgs, (address[], address, address));
    }

    /// @notice Get the custom arguments of the proxy.
    function getCustomArgs()
        external
        view
        returns (address[] memory rewardTokens, address distributor, address treasury)
    {
        return _getCustomArgs(address(this)); // In regular context, reward proxy is `address(this)`
    }

    function VERSION() external pure override returns (bytes32) {
        return "2.0.0";
    }

    /// @notice Storage slot for the ERC7201 storage.
    function _getStorage() internal pure returns (MorphoRewardProxyStorage storage $) {
        assembly {
            $.slot := MORPHO_REWARD_PROXY_STORAGE_LOCATION
        }
    }
}
