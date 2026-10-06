// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {IPool} from "src/wrapper/aave-v3/interfaces/IPool.sol";
import {IScaledBalanceToken} from "./IScaledBalanceToken.sol";

interface IAToken is IScaledBalanceToken {
    /// @notice The address of the Aave v3 pool instance
    function POOL() external view returns (IPool);

    /// @notice The address of the underlying asset of the aToken e.g. WETH for aWETH
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}
