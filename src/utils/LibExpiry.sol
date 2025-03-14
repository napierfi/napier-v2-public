// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {EIP5095} from "../interfaces/EIP5095.sol";

library LibExpiry {
    function isExpired(uint256 expiry) internal view returns (bool) {
        return block.timestamp >= expiry;
    }

    function isExpired(EIP5095 pt) internal view returns (bool) {
        return block.timestamp >= pt.maturity();
    }

    function isNotExpired(EIP5095 pt) internal view returns (bool) {
        return block.timestamp < pt.maturity();
    }
}
