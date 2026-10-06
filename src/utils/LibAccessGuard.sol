// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {AccessManager} from "../modules/AccessManager.sol";
import {LibMulticaller} from "multicaller/src/LibMulticaller.sol";
import "../Errors.sol";

library LibAccessGuard {
    /// @notice Reverts with `Errors.AccessManaged_Restricted()` when the caller lacks permission.
    /// @param accessManager The `AccessManager` contract controlling the access permissions
    function checkRestricted(AccessManager accessManager) internal view {
        if (!accessManager.canCall(LibMulticaller.senderOrSigner(), address(this), bytes4(msg.data[0:4]))) {
            revert Errors.AccessManaged_Restricted();
        }
    }

    /// @notice Reverts with `Errors.AccessManaged_Restricted()` when the caller lacks permission.
    /// @param accessManager The `AccessManager` contract controlling the access permissions
    /// @param selector The function selector to check permissions for
    /// @dev Use this overload when checking permissions in a delegatecall context where
    ///      `bytes4(msg.data[0:4])` would return the wrong function selector. In delegatecall,
    ///      you need to explicitly provide the original function selector that users call.
    function checkRestricted(AccessManager accessManager, bytes4 selector) internal view {
        if (!accessManager.canCall(LibMulticaller.senderOrSigner(), address(this), selector)) {
            revert Errors.AccessManaged_Restricted();
        }
    }
}
