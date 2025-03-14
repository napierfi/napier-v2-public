// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";

type RewardIndex is uint128;

/// @notice A struct to store the reward information for a user.
/// @param userIndex The reward index when the user last accrued reward.
/// @param accrued The accrued reward since the last time the user accrued reward.
struct Reward {
    RewardIndex userIndex; // rewardIndex_u(t_1): the reward index when the user last accrued reward
    uint128 accrued; // r_u(t_1): the accrued reward since the last time the user accrued reward
}

using {unwrap} for RewardIndex global;
using {eq as ==, add as +, sub as -} for RewardIndex global;

function unwrap(RewardIndex x) pure returns (uint128 result) {
    result = RewardIndex.unwrap(x);
}

function wrap(uint128 x) pure returns (RewardIndex result) {
    result = RewardIndex.wrap(x);
}

function eq(RewardIndex lhs, RewardIndex rhs) pure returns (bool output) {
    assembly {
        let m := shr(128, not(0))
        output := eq(and(m, lhs), and(m, rhs))
    }
}

function add(RewardIndex lhs, RewardIndex rhs) pure returns (RewardIndex output) {
    output = wrap(lhs.unwrap() + rhs.unwrap());
}

function sub(RewardIndex lhs, RewardIndex rhs) pure returns (RewardIndex output) {
    output = wrap(lhs.unwrap() - rhs.unwrap());
}

/// @notice A library to help calculate reward for users.
/// @notice The reward is distributed proportionally to the user's YT balance.
/// @dev Conceptually, this algorithm is the same as the staking algorithm of Synthetix and MasterChef.
/// @dev Important security note: Any user may be griefed by a malicious user by updating the reward index frequently.
/// When small amount of reward is accrued and ytSupply is way larger than totalAccrued, those rewards may be lost.
/// Impact: The whole reward income for a user may be frozen.
/// @dev When YT supply is 0 but some reward is accrued, the reward will be lost.
/// @dev Note Reward token should have enough decimals and YT decimals should have no more than 18 decimals.
/// @dev Rebase token and fee-on-transfer token are not supported.
library RewardMathLib {
    using SafeCastLib for uint256;

    /// @notice Update the reward index for newly accrued reward.
    /// @dev Assumption: If ytSupply is 0, totalAccrued is also 0. When ytSupply is 0 but totalAccrued is non-zero, the reward will be lost.
    /// @param index The last index to update from. rewardIndex(t_1)
    /// @param ytSupply The total YT supply. totalSupply(t_2)
    /// @param totalAccrued The total accrued reward since the last update. d(t_2)
    /// @return newIndex The up-to-date reward index. rewardIndex(t_2)
    /// @return lostReward The reward lost due to the rounding error.
    function updateIndex(RewardIndex index, uint256 ytSupply, uint256 totalAccrued)
        internal
        pure
        returns (RewardIndex newIndex, uint256 lostReward)
    {
        // When ytSupply is 0 but totalAccrued is non-zero, the reward will be lost.
        if (ytSupply == 0) return (index, totalAccrued);
        //                       N
        //                     _____
        //                     ╲
        //                      ╲     totalAccrued
        //                       ╲                 i
        // globalRewardIndex =   ╱   ────────────────
        //                      ╱        ytSupply
        //                     ╱                  i
        //                     ‾‾‾‾‾
        //                     i = 0
        // Note newIndex may not increase and small amount of reward may be lost when totalAccrued is small and ytSupply is way larger than totalAccrued.
        // e.g.
        // 1) totalAccrued = 1400, ytSupply = 5.57e23 => totalAccrued * 1e18 / ytSupply = 0.002519345 ~ 0. This 1400 reward will be lost.
        // 2) totalAccrued = 3.12e9 ytSupply = 6.017e23 => totalAccrued * 1e18 / ytSupply = 5,185.3082931694 ~ 5,185.
        // It means 185,500 (= totalAccrued - 5185 * ytSupply / 1e18 = 3.12e9 - 3,119,814,500) reward will be lost.
        newIndex = index + RewardIndex.wrap(FixedPointMathLib.divWad(totalAccrued, ytSupply).toUint128());
        lostReward = totalAccrued - FixedPointMathLib.mulWad(ytSupply, (newIndex - index).unwrap()); // Never underflow
    }

    /// @notice Update the accrued reward for a user `account` since the last time when `account` accrued reward based on the `account`'s YT balance `ytBalance`.
    /// @dev Assumption: `index` is always greater than or equal to `userIndex`
    /// @param index The up-to-date reward index.
    /// @param account The account to update the reward for.
    /// @param ytBalance The `account`'s YT balance.
    function accrueUserReward(
        mapping(address user => Reward userReward) storage self,
        RewardIndex index, // rewardIndex(t_2)
        address account, // u
        uint256 ytBalance // ytBalance_u
    ) internal {
        RewardIndex prevIndex = self[account].userIndex;
        // r  ⎛t ⎞     = r  ⎛t ⎞      + ytBalance  ⋅ ⎛rewardIndex ⎛t ⎞ - rewardIndex ⎛t ⎞⎞
        //  u ⎝ 2⎠        u ⎝ 1⎠                 u   ⎝            ⎝ 2⎠               ⎝ 1⎠⎠
        uint256 accrued = FixedPointMathLib.mulWad(ytBalance, RewardIndex.unwrap(index - prevIndex)); // d_u(t_2)
        self[account].accrued += accrued.toUint128(); // r_u(t_2) = r_u(t_1) + d_u(t_2)
        self[account].userIndex = index;
    }
}
