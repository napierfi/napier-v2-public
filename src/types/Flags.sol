// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {Flags16} from "../Types.sol";

function unwrap(Flags16 flags) pure returns (uint16) {
    return Flags16.unwrap(flags);
}
