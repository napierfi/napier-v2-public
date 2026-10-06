// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {TwoCrypto} from "../Types.sol";

function unwrap(TwoCrypto x) pure returns (address result) {
    result = TwoCrypto.unwrap(x);
}
