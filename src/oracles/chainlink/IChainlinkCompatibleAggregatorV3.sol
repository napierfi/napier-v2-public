// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "../../lens/external/AggregatorV3Interface.sol";

interface IChainlinkCompatibleAggregatorV3 is AggregatorV3Interface {
    /// @notice Initialize the aggregator with the given data
    /// @param data The data to initialize the aggregator with
    function initialize(bytes calldata data) external;

    /// @notice Label for oracle
    function label() external view returns (bytes32);
}
