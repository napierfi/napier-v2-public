// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

/// @notice Standard interface for deploying pools
interface IPoolDeployer {
    function deploy(address target, address principalToken, bytes calldata initArgs)
        external
        payable
        returns (address);
}
