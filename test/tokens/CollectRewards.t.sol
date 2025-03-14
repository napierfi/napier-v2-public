// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {PrincipalTokenTest} from "../shared/PrincipalToken.t.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";

import {Errors} from "src/Errors.sol";
import {Events} from "src/Events.sol";

contract CollectRewardsTest is PrincipalTokenTest {
    using stdStorage for StdStorage;

    uint256[] toyRewards;

    function setUp() public override {
        super.setUp();

        // Toy data setup: alice has some rewards
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            uint256 userIndex = i + 1;
            uint256 rewards = 1e9 * (i + 1);
            toyRewards.push(rewards);
            deal(rewardTokens[i], address(principalToken), rewards);
            uint256 slot = stdstore.target(address(principalToken)).sig("getUserReward(address,address)").with_key(
                rewardTokens[i]
            ).with_key(alice).find();
            vm.store(address(principalToken), bytes32(slot), bytes32(rewards << 128 | userIndex));
            assertEq(principalToken.getUserReward(rewardTokens[i], alice).accrued, rewards, "Rewards setup");
        }
    }

    function test_CollectRewards() public {
        // Emit the expected events
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            vm.expectEmit(true, true, true, true);
            emit Events.RewardsCollected({
                by: alice,
                receiver: bob,
                owner: alice,
                rewardToken: rewardTokens[i],
                rewards: toyRewards[i]
            });
        }

        // Execute
        vm.prank(alice);
        uint256[] memory result = principalToken.collectRewards(rewardTokens, bob, alice);

        assertEq(result.length, rewardTokens.length, "Length mismatch");
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            assertEq(result[i], toyRewards[i], "Rewards to collect");
            assertEq(ERC20(rewardTokens[i]).balanceOf(bob), toyRewards[i], "Rewards collected");
        }

        // Check that the rewards are zeroed out after collection
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            assertEq(principalToken.getUserReward(rewardTokens[i], alice).accrued, 0, "Rewards zeroed out");
        }
    }

    function test_WhenDuplicatedRewardTokens() public {
        require(rewardTokens.length > 1, "TEST-ASSUMPTION: Need at least 2 reward tokens");
        rewardTokens[1] = rewardTokens[0]; // Duplicate the first reward token

        vm.prank(alice);
        uint256[] memory result = principalToken.collectRewards(rewardTokens, bob, alice);

        assertEq(result.length, rewardTokens.length, "Length mismatch");
        assertEq(result[0], toyRewards[0], "Rewards to collect");
        assertEq(result[1], 0, "Duplicate rewards should be zero");
    }

    function test_RevertWhen_NotApproved() public {
        vm.expectRevert(Errors.PrincipalToken_NotApprovedCollector.selector);
        vm.prank(alice);
        principalToken.collectRewards(rewardTokens, bob, bob);

        vm.prank(bob); // Owner can collect without approval
        principalToken.collectRewards(rewardTokens, bob, bob);
    }

    function test_RevertWhen_RewardTokenIsUnderlying() public {
        rewardTokens[1] = address(target);

        vm.expectRevert(Errors.PrincipalToken_ProtectedToken.selector);
        vm.prank(alice);
        principalToken.collectRewards(rewardTokens, bob, alice);
    }
}
