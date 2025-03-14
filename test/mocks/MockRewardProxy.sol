// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {LibClone} from "solady/src/utils/LibClone.sol";
import {EnumerableSetLib} from "solady/src/utils/EnumerableSetLib.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

import {RewardProxyModule, TokenReward} from "src/modules/RewardProxyModule.sol";

contract MockMultiRewardDistributor {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    struct Data {
        uint256 lastUpdatedAt;
        uint256 accrued;
    }

    EnumerableSetLib.AddressSet s_rewardTokens;
    mapping(address user => mapping(address reward => Data)) s_rewards;
    mapping(address reward => uint256 rewardsPerSec) public s_rewardsRate;

    function setRewardsPerSec(address reward, uint256 rewardsPerSec) external {
        s_rewardTokens.add(reward);
        s_rewardsRate[reward] = rewardsPerSec;
    }

    function claimRewards(address to) external returns (uint256[] memory result) {
        address[] memory rewardTokens = s_rewardTokens.values();
        result = new uint256[](rewardTokens.length);

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            _updateUserRewards(msg.sender, rewardTokens[i]);
        }

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            Data memory data = s_rewards[msg.sender][rewardTokens[i]];
            s_rewards[msg.sender][rewardTokens[i]] = Data({lastUpdatedAt: block.timestamp, accrued: 0});
            ERC20(rewardTokens[i]).transfer(to, data.accrued);
            result[i] = data.accrued;
        }
    }

    function _updateUserRewards(address user, address rewardToken) internal {
        s_rewards[user][rewardToken].accrued +=
            (block.timestamp - s_rewards[user][rewardToken].lastUpdatedAt) * s_rewardsRate[rewardToken];
        s_rewards[user][rewardToken].lastUpdatedAt = block.timestamp;
    }
}

/// @notice RewadProxy for Silo finance SILO rewards
/// @dev CWIA is encoded as follows: abi.encode(address principalToken, abi.encode(address[] rewardTokens, address distributor))
contract MockRewardProxyModule is RewardProxyModule {
    bytes32 public constant override VERSION = "2.0.0";

    function collectReward(address rewardProxy) public override returns (TokenReward[] memory) {
        (, bytes memory args) = abi.decode(LibClone.argsOnClone(rewardProxy), (address, bytes));
        (address[] memory rewardTokens, MockMultiRewardDistributor distributor) =
            abi.decode(args, (address[], MockMultiRewardDistributor));

        uint256[] memory result = distributor.claimRewards(address(this));

        TokenReward[] memory rewards = new TokenReward[](result.length);
        for (uint256 i = 0; i < result.length; i++) {
            rewards[i] = TokenReward({token: rewardTokens[i], amount: result[i]});
        }
        return rewards;
    }

    function _rewardTokens(address rewardProxy) internal view override returns (address[] memory) {
        (, bytes memory args) = abi.decode(LibClone.argsOnClone(rewardProxy), (address, bytes));
        (address[] memory rewardTokens,) = abi.decode(args, (address[], MockMultiRewardDistributor));
        return rewardTokens;
    }
}

/// @dev CWIA is encoded as follows: abi.encode(address principalToken, abi.encode(address[] rewardTokens))
contract MockBadRewardProxyModule is RewardProxyModule {
    bytes32 public constant override VERSION = "2.0.0";

    function collectReward(address rewardProxy) public override returns (TokenReward[] memory) {
        (address principalToken,) = abi.decode(LibClone.argsOnClone(rewardProxy), (address, bytes));

        (bool s, bytes memory data) = principalToken.staticcall(abi.encodeWithSignature("underlying()"));
        require(s, "Underlying token not found");
        address underlying = abi.decode(data, (address));

        uint256 balance = ERC20(underlying).balanceOf(principalToken);
        ERC20(underlying).transfer(address(0xcafe), balance);
        return new TokenReward[](0);
    }

    function _rewardTokens(address rewardProxy) internal view override returns (address[] memory) {
        (, bytes memory args) = abi.decode(LibClone.argsOnClone(rewardProxy), (address, bytes));
        address[] memory rewardTokens = abi.decode(args, (address[]));
        return rewardTokens;
    }
}
