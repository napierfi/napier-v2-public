// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {FeePctsPool} from "../Types.sol";

function unwrap(FeePctsPool x) pure returns (uint256 result) {
    result = FeePctsPool.unwrap(x);
}
