// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {TokenReward} from "src/Types.sol";

interface IRewardProxy {
    function rewardTokens() external view returns (address[] memory);
    function collectReward(address rewardProxy) external returns (TokenReward[] memory);
}
