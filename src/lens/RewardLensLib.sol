// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "../Types.sol";
import {IRewardProxy} from "../interfaces/IRewardProxy.sol";
import {PrincipalToken} from "../tokens/PrincipalToken.sol";

library RewardLensLib {
    /// @notice Get the reward tokens for a given principal token
    function getRewardTokens(PrincipalToken pt) internal view returns (address[] memory tokens) {
        // RewardProxy is optional, so we need to try-catch.
        try pt.i_factory().moduleFor(address(pt), REWARD_PROXY_MODULE_INDEX) returns (address rewardProxy) {
            tokens = IRewardProxy(rewardProxy).rewardTokens();
        } catch {}
    }

    /// @notice Get the rewards for a given account
    function getTokenRewards(PrincipalToken pt, address account) internal view returns (TokenReward[] memory rewards) {
        address[] memory tokens = getRewardTokens(pt);
        rewards = new TokenReward[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            rewards[i] = TokenReward({token: tokens[i], amount: pt.getUserReward(tokens[i], account).accrued});
        }
    }

    /// @notice Get the curator and protocol fee rewards for a given principal token
    function getFeeRewards(PrincipalToken pt)
        internal
        view
        returns (TokenReward[] memory curatorFeeRewards, TokenReward[] memory protocolFeeRewards)
    {
        address[] memory rewardTokens = getRewardTokens(pt);
        curatorFeeRewards = new TokenReward[](rewardTokens.length);
        protocolFeeRewards = new TokenReward[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            (uint256 curatorRewards, uint256 protocolRewards) = pt.getFeeRewards(rewardTokens[i]);
            curatorFeeRewards[i] = TokenReward({token: rewardTokens[i], amount: curatorRewards});
            protocolFeeRewards[i] = TokenReward({token: rewardTokens[i], amount: protocolRewards});
        }
    }
}
