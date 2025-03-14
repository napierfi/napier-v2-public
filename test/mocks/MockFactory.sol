// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "src/Constants.sol" as Constants;

contract MockFactory {
    address public immutable i_accessManager;
    uint256 public constant DEFAULT_SPLIT_RATIO_BPS = Constants.DEFAULT_SPLIT_RATIO_BPS;

    constructor(address _accessManager) {
        i_accessManager = _accessManager;
    }
}
