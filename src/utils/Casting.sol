// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "solady/src/tokens/ERC20.sol";

library Casting {
    function asAddr(ERC20 x) internal pure returns (address) {
        return address(x);
    }
}
