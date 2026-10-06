// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

/// @dev Interface for Silo Incentives Controller
interface ISiloIncentivesController {
    struct AccruedRewards {
        uint256 amount;
        bytes32 programId;
        address rewardToken;
    }

    function claimRewards(address _to) external returns (AccruedRewards[] memory accruedRewards);
    function claimRewards(address _to, string[] calldata _programNames)
        external
        returns (AccruedRewards[] memory accruedRewards);
    function getRewardsBalance(address _user, string[] calldata _programNames)
        external
        view
        returns (uint256 unclaimedRewards);
}
