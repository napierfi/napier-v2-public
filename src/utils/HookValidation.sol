// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {LibTransient} from "solady/src/utils/LibTransient.sol";

import {Errors} from "../Errors.sol";
import {CustomRevert} from "./CustomRevert.sol";

/// @notice HookValidation is a contract that provides a authorization mechanism for callback receiver.
abstract contract HookValidation {
    using CustomRevert for bytes4;

    /// @dev Slot for the callback authorization.
    /// After the callback, the caller should call `verifyAndClearHookContext` to clear the context.
    LibTransient.TBool internal hookContext;

    function verifyAndClearHookContext() internal {
        bool context = LibTransient.getCompat(hookContext);
        LibTransient.clearCompat(hookContext);
        if (!context) Errors.Zap_BadCallback.selector.revertWith();
    }

    function setHookContext() internal {
        LibTransient.setCompat(hookContext, true);
    }
}
