// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

interface IBooster {
    struct PoolInfo {
        address lpToken;
        address token;
        address gauge;
        address crvRewards;
        address stash;
        bool shutdown;
    }

    function poolInfo(uint256 _pid) external view returns (address, address, address, address, address, bool);
    function depositAll(uint256 _pid, bool _stake) external returns (bool);
    function deposit(uint256 _pid, uint256 _amount, bool _stake) external returns (bool);
    function withdraw(uint256 _pid, uint256 _amount) external returns (bool);
}
