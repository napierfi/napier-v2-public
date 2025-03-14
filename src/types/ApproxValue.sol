// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {ApproxValue} from "../Types.sol";

function unwrap(ApproxValue x) pure returns (uint256 result) {
    result = ApproxValue.unwrap(x);
}
