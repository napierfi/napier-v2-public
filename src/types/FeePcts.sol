// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {FeePcts} from "../Types.sol";

function unwrap(FeePcts x) pure returns (uint256 result) {
    result = FeePcts.unwrap(x);
}
