// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

abstract contract LibApproval {
    /// @dev The approval slot of (`src`, `spender`) is given by:
    /// ```
    ///     mstore(0x20, spender)
    ///     mstore(0x0c, _IS_APPROVED_SLOT_SEED)
    ///     mstore(0x00, src)
    ///     let allowanceSlot := keccak256(0x0c, 0x34)
    /// ```
    /// @dev Optimized storage slot for approval flags
    /// `mapping (address src => mapping (address spender => uint256 approved)) isApproved;`
    uint256 constant _IS_APPROVED_SLOT_SEED = 0xa8fe4407;

    /// @dev Get the approval status of the `spender` for the `src`. Return true if approved, 0 otherwise.
    function isApproved(address src, address spender) internal view returns (bool approved) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x20, spender)
            mstore(0x0c, _IS_APPROVED_SLOT_SEED)
            mstore(0x00, src)
            approved := sload(keccak256(0x0c, 0x34))
        }
    }

    /// @dev Set the approval status to 1 for the spender for the src.
    function setApproval(address src, address spender, bool approved) internal {
        /// @solidity memory-safe-assembly
        assembly {
            // Compute the approval slot and store the amount.
            mstore(0x20, spender)
            mstore(0x0c, _IS_APPROVED_SLOT_SEED)
            mstore(0x00, src)
            sstore(keccak256(0x0c, 0x34), approved)
        }
    }

    function approveIfNeeded(address token, address spender) internal {
        if (!isApproved(token, spender)) {
            setApproval(token, spender, true);
            SafeTransferLib.safeApprove(token, spender, type(uint256).max);
        }
    }
}
