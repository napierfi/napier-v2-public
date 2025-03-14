// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {TwoCrypto} from "../Types.sol";

function unwrap(TwoCrypto x) pure returns (address result) {
    result = TwoCrypto.unwrap(x);
}
