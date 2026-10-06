// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {LibClone} from "solady/src/utils/LibClone.sol";

import {IMerkl} from "../../interfaces/external/IMerkl.sol";

import {ContractValidation} from "../../utils/ContractValidation.sol";
import "../../Types.sol";
import "../../Errors.sol";

import {RewardProxyModule} from "../RewardProxyModule.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

/// @dev Namespace has to be used for avoiding storage slot collisions.
/// @dev ABI-encoded custom args: `(address[] rewardTokens, address distributor, address operator, address treasury)`
contract MerklRewardProxy is RewardProxyModule {
    /// @custom:storage-location `keccak256(abi.encode(uint256(keccak256("napier-v2.storage.merkl-reward-proxy")) - 1)) & ~bytes32(uint256(0xff))`
    bytes32 constant MERKL_REWARD_PROXY_STORAGE_LOCATION =
        0x0268a7dd6085b8e7685b7b87385568b2c2ca5dbcd043f363b446f62bd79cb200;

    struct Claimed {
        uint208 amount;
        uint48 timestamp;
    }

    struct MerklRewardProxyStorage {
        /// @notice Total amount claimed so far for each reward token.
        mapping(address rewardToken => Claimed) lastClaimed;
    }

    function initialize() public override initializer {
        (address[] memory tokens, address distributor, address operator, address treasury) =
            _getCustomArgs(address(this));

        // Validate params
        if (!ContractValidation.hasCode(distributor)) revert Errors.MerklRewardProxy_InvalidDistributor();
        if (treasury == address(0)) revert Errors.MerklRewardProxy_InvalidTreasury();
        if (operator == address(0)) revert Errors.MerklRewardProxy_InvalidOperator();

        // Tokens must be sorted in ascending order
        require(tokens.length > 0);
        for (uint256 i = 0; i < tokens.length - 1; i++) {
            if (tokens[i] >= tokens[i + 1]) revert Errors.RewardProxy_InconsistentRewardTokens();
        }
    }

    /// @dev This function is called by a principalToken in delegate call context.
    /// @dev Don't make a delegate call to an external contract inside this function.
    /// @dev We toggle operator because principal token contract cannot claim rewards by itself, we need another address to claim on its behalf.
    function collectReward(address rewardProxy) public override returns (TokenReward[] memory) {
        MerklRewardProxyStorage storage $ = _getStorage();

        (address[] memory rewardTokens, address distributor, address operator, address treasury) =
            _getCustomArgs(rewardProxy);

        if (IMerkl(distributor).operators(address(this), operator) == 0) {
            IMerkl(distributor).toggleOperator(address(this), operator);
        }

        TokenReward[] memory tokenRewards = new TokenReward[](0);

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address reward = rewardTokens[i];

            Claimed memory lastClaimed = $.lastClaimed[reward];

            // Get the amount of reward tokens claimed so far from the Merkl distributor
            IMerkl.Claim memory claimed = IMerkl(distributor).claimed(address(this), reward);

            // Calculate newly collected rewards since last claim
            uint256 collected;
            if (claimed.amount > lastClaimed.amount) {
                collected = claimed.amount - lastClaimed.amount;
                $.lastClaimed[reward] = Claimed({amount: claimed.amount, timestamp: claimed.timestamp});
            }
            SafeTransferLib.safeTransfer(reward, treasury, collected);
        }

        return tokenRewards;
    }

    function _rewardTokens(address rewardProxy) internal view override returns (address[] memory rewardTokens) {
        (rewardTokens,,,) = _getCustomArgs(rewardProxy);
    }

    /// @notice Decode the custom arguments of the proxy from `immutableArgs = abi.encode(principalToken, customArgs)`.
    /// @dev Internal function for both regular and delegate call context.
    function _getCustomArgs(address rewardProxy)
        internal
        view
        returns (address[] memory rewardTokens, address distributor, address operator, address treasury)
    {
        bytes memory args = LibClone.argsOnClone(rewardProxy);
        (, bytes memory customArgs) = abi.decode(args, (address, bytes));
        (rewardTokens, distributor, operator, treasury) = abi.decode(customArgs, (address[], address, address, address));
    }

    /// @notice Get the custom arguments of the proxy.
    function getCustomArgs()
        external
        view
        returns (address[] memory rewardTokens, address distributor, address operator, address treasury)
    {
        return _getCustomArgs(address(this)); // In regular context, reward proxy is `address(this)`
    }

    function VERSION() external pure override returns (bytes32) {
        return "2.0.0";
    }

    /// @notice Storage slot for the ERC7201 storage.
    function _getStorage() internal pure returns (MerklRewardProxyStorage storage $) {
        assembly {
            $.slot := MERKL_REWARD_PROXY_STORAGE_LOCATION
        }
    }
}
