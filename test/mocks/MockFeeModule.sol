// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {FeeModule} from "src/modules/FeeModule.sol";
import {FeePcts} from "src/Types.sol";

contract MockFeeModule is FeeModule {
    FeePcts s_feePcts;

    bytes32 public constant override VERSION = "2.0.0";

    function setFeePcts(FeePcts v) external {
        s_feePcts = v;
    }

    function getFeePcts() external view override returns (FeePcts) {
        return s_feePcts;
    }

    function initialize() external override {}
}
