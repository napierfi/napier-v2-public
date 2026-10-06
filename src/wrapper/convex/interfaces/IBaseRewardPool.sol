// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

interface IBaseRewardPool {
    function balanceOf(address account) external view returns (uint256);
    function earned(address account) external view returns (uint256);
    function rewardToken() external view returns (address);
    function extraRewardsLength() external view returns (uint256);
    function extraRewards(uint256) external view returns (address);
    function getReward() external returns (bool);
    function getReward(address _account, bool _claimExtras) external returns (bool);
    function stake(uint256 _amount) external returns (bool);
    function stakeFor(address _for, uint256 _amount) external returns (bool);
    function withdraw(uint256 amount, bool claim) external returns (bool);
    function withdrawAndUnwrap(uint256 amount, bool claim) external returns (bool);
}
