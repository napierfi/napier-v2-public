// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import "../Property.sol" as Property;

import {RewardMathLib, RewardIndex, Reward} from "src/utils/RewardMathLib.sol";

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {EnumerableSetLib} from "solady/src/utils/EnumerableSetLib.sol";

contract RewardMathLibInvariant is Test {
    RewardMathHandler math;
    Ghost ghost;

    function setUp() public {
        ghost = new Ghost();
        math = new RewardMathHandler(ghost);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = math.mint.selector;
        selectors[1] = math.burn.selector;
        selectors[2] = math.transfer.selector;
        selectors[3] = math.claim.selector;

        targetSelector(FuzzSelector({addr: address(math), selectors: selectors}));

        targetContract(address(math));
        excludeContract(address(ghost));
    }

    function invariant_rewardIndexNeverDecrease() external view {
        assertGe(
            RewardIndex.unwrap(math.s_rewardIndex()),
            RewardIndex.unwrap(math.s_lastRewardIndex()),
            Property.T09_REWARD_INDEX
        );
    }

    function invariant_userRewards() external {
        address[] memory users = ghost.users();

        for (uint256 i = 0; i < users.length; i++) {
            uint256 reward = math.claim(users[i]);
            Ghost.Ghost_Reward memory ghost_reward = ghost.ghost_reward(users[i]);
            // It's impossible that the actual reward is exactly equal to the expected reward
            // because of precision loss in the reward calculation. See `RewardMathLib.updateIndex`
            // Some rewards are permanently lost due to rounding errors.
            // Therefore, we only check sum of rewards is less than or equal to the theoretical maximum rewards.
            assertLe(reward, ghost_reward.ghost_sumAccrued, Property.T08_REWARD_EQ);
        }
    }

    function invariant_totalRewards() external {
        address[] memory users = ghost.users();

        (uint256 ghost_totalRewardsAccrued, uint256 ghost_totalRewardsLost) = ghost.ghost_totalRewards();
        uint256 totalAccrued;
        for (uint256 i = 0; i < users.length; i++) {
            totalAccrued += math.claim(users[i]);
        }
        assertApproxEqAbs(totalAccrued, ghost_totalRewardsAccrued - ghost_totalRewardsLost, 100, Property.T07_REWARD);
    }

    function invariant_callSummary() public view {
        math.summary();
    }
}

/// @dev Toy contract
contract RewardMathHandler is StdAssertions, StdUtils {
    mapping(address user => Reward) s_rewards;
    RewardIndex public s_lastRewardIndex;
    RewardIndex public s_rewardIndex;

    // ERC20 balances of reward generating token
    uint256 s_totalSupply;
    mapping(address user => uint256 balance) s_balanceOf;

    Ghost s_ghost;

    mapping(string method => uint256) s_counters;

    /// @dev Debug flag to print logs
    bool s_debug;

    constructor(Ghost _ghost) {
        s_ghost = _ghost;
    }

    function mint(address user, uint256 value, uint256 newAccrued) public counter("mint") {
        value = _bound(value, 0, type(uint80).max);
        newAccrued = _bound(newAccrued, 0, type(uint80).max);

        if (s_totalSupply == 0) newAccrued = 0; // If deposit is 0, no rewards are accrued
        if (s_debug) console2.log("value, newAccrued :>>", value, newAccrued);

        (RewardIndex newIndex, uint256 lostReward) = RewardMathLib.updateIndex(s_rewardIndex, s_totalSupply, newAccrued);
        RewardMathLib.accrueUserReward(s_rewards, newIndex, user, s_balanceOf[user]);
        if (s_debug) console2.log("newIndex: %e, user accrued: %e ", newIndex.unwrap(), s_rewards[user].accrued);

        s_ghost.add_user(user);
        s_ghost.add_totalReward(newAccrued, lostReward);
        _updateGhostUserRewards(newAccrued);

        s_lastRewardIndex = s_rewardIndex;
        s_rewardIndex = newIndex;
        s_totalSupply += value;
        s_balanceOf[user] += value;
    }

    function burn(uint256 seed, uint256 value, uint256 newAccrued) public counter("burn") {
        address user = s_ghost.rand(seed);
        if (user == address(0)) return;

        value = _bound(value, 0, s_balanceOf[user]);
        newAccrued = _bound(newAccrued, 0, type(uint80).max);
        if (s_totalSupply == 0) newAccrued = 0; // If deposit is 0, no rewards are accrued
        if (s_debug) console2.log("value, newAccrued :>>", value, newAccrued);

        (RewardIndex newIndex, uint256 lostReward) = RewardMathLib.updateIndex(s_rewardIndex, s_totalSupply, newAccrued);
        RewardMathLib.accrueUserReward(s_rewards, newIndex, user, s_balanceOf[user]);
        if (s_debug) console2.log("newIndex: %e, user accrued: %e ", newIndex.unwrap(), s_rewards[user].accrued);

        s_ghost.add_totalReward(newAccrued, lostReward);
        _updateGhostUserRewards(newAccrued);

        s_lastRewardIndex = s_rewardIndex;
        s_rewardIndex = newIndex;
        s_balanceOf[user] -= value;
        s_totalSupply -= value;
    }

    function transfer(uint256 seed, address receiver, uint256 value, uint256 newAccrued) public counter("transfer") {
        address owner = s_ghost.rand(seed);
        if (owner == address(0)) return;

        value = _bound(value, 0, s_balanceOf[owner]);
        newAccrued = _bound(newAccrued, 0, type(uint80).max);
        if (s_totalSupply == 0) newAccrued = 0;
        if (s_debug) console2.log("value, newAccrued :>>", value, newAccrued);

        (RewardIndex newIndex, uint256 lostReward) = RewardMathLib.updateIndex(s_rewardIndex, s_totalSupply, newAccrued);
        RewardMathLib.accrueUserReward(s_rewards, newIndex, owner, s_balanceOf[owner]);
        RewardMathLib.accrueUserReward(s_rewards, newIndex, receiver, s_balanceOf[receiver]);
        if (s_debug) {
            console2.log("newIndex: %e, owner accrued: %e ", newIndex.unwrap(), s_rewards[owner].accrued);
            console2.log("newIndex: %e, receiver accrued: %e ", newIndex.unwrap(), s_rewards[receiver].accrued);
        }
        s_ghost.add_user(receiver);
        s_ghost.add_totalReward(newAccrued, lostReward);
        _updateGhostUserRewards(newAccrued);

        s_lastRewardIndex = s_rewardIndex;
        s_rewardIndex = newIndex;
        s_balanceOf[owner] -= value;
        s_balanceOf[receiver] += value;
    }

    function claim(address user) public counter("claim") returns (uint256) {
        s_lastRewardIndex = s_rewardIndex;
        (RewardIndex newIndex, uint256 lostReward) = RewardMathLib.updateIndex(s_rewardIndex, s_totalSupply, 0);
        RewardMathLib.accrueUserReward(s_rewards, newIndex, user, s_balanceOf[user]);

        assertEq(s_lastRewardIndex.unwrap(), newIndex.unwrap(), "rewardIndex should not be updated");
        assertEq(lostReward, 0, "lostReward should be 0");

        if (s_debug) console2.log("newIndex: %e, user accrued: %e ", newIndex.unwrap(), s_rewards[user].accrued);

        s_ghost.add_user(user);

        return s_rewards[user].accrued;
    }

    function rewardOf(address user) public view returns (uint256) {
        return s_rewards[user].accrued;
    }

    //                                ⎛s  ⎛t ⎞⎞
    //                                ⎜ u ⎝ 2⎠⎟
    //                                ⎜       ⎟
    // r  ⎛t ⎞  = r  ⎛t ⎞  + d ⎛t ⎞ ⋅ ⎜───────⎟
    //  u ⎝ 2⎠     u ⎝ 1⎠      ⎝ 2⎠   ⎜S ⎛t ⎞ ⎟
    //                                ⎝  ⎝ 2⎠ ⎠
    /// @dev For all users, compute *theoretical maximum* accrued rewards for each user.
    function _updateGhostUserRewards(uint256 newAccrued) internal {
        address[] memory users = s_ghost.users();
        for (uint256 i = 0; i < users.length; i++) {
            uint256 su = s_balanceOf[users[i]];
            uint256 S = s_totalSupply;
            uint256 d = newAccrued;
            // Note: Rounding up is necessary. We want to compute theoretical maximum rewards that can be accrued by the user.
            // If rounding down, rounding errors will accumulate and the sum of rewards may be less than the `RewardMathLib` implementation
            uint256 reward = S > 0 ? FixedPointMathLib.mulDivUp(d, su, S) : 0; // S == 0 means no rewards were accrued
            s_ghost.add_userReward(users[i], reward);
            if (s_debug) console2.log("user, ghost_reward :>>", users[i], reward);
        }
    }

    function summary() public view {
        console2.log("s_counters['mint'] :>>", s_counters["mint"]);
        console2.log("s_counters['burn'] :>>", s_counters["burn"]);
        console2.log("s_counters['transfer'] :>>", s_counters["transfer"]);
        console2.log("s_counters['claim'] :>>", s_counters["claim"]);
    }

    modifier counter(string memory method) {
        s_counters[method]++;
        _;
    }
}

contract Ghost is TestBase, StdUtils {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    struct Ghost_TotalRewards {
        uint256 ghost_totalRewardsAccrued;
        uint256 ghost_totalRewardsLost;
    }

    Ghost_TotalRewards public ghost_totalRewards;

    struct Ghost_Reward {
        uint256 ghost_sumAccrued; // expected reward accrued including actual reward lost
    }

    EnumerableSetLib.AddressSet ghost_users;
    mapping(address user => Ghost_Reward) ghost_userRewards;

    function add_user(address _user) external {
        bool added = ghost_users.add(_user);
        if (added) vm.label(_user, string.concat("user", vm.toString(ghost_users.length())));
    }

    function add_totalReward(uint256 accrued, uint256 lost) external {
        ghost_totalRewards.ghost_totalRewardsAccrued += accrued;
        ghost_totalRewards.ghost_totalRewardsLost += lost;
    }

    function add_userReward(address _user, uint256 reward) external {
        ghost_userRewards[_user].ghost_sumAccrued += reward;
    }

    function ghost_reward(address _user) external view returns (Ghost_Reward memory) {
        return ghost_userRewards[_user];
    }

    function rand(uint256 seed) external view returns (address) {
        if (ghost_users.length() == 0) return address(0);
        return ghost_users.at(seed % ghost_users.length());
    }

    function users() external view returns (address[] memory) {
        return ghost_users.values();
    }
}
