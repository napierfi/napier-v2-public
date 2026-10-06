// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

interface IScaledBalanceToken {
    function scaledTotalSupply() external view returns (uint256);
}
