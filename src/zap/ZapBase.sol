// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {ReentrancyGuardTransient} from "solady/src/utils/ReentrancyGuardTransient.sol";

import {LibApproval} from "../utils/LibApproval.sol";

import {Errors} from "../Errors.sol";

abstract contract ZapBase is ReentrancyGuardTransient, LibApproval {
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert Errors.Zap_TransactionTooOld();
        _;
    }
}
