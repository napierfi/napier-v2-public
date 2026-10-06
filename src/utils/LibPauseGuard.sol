// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Flags16} from "../Types.sol";
import "../Errors.sol";

library LibPauseGuard {
    /// @notice Reverts with `Errors.LibPauseGuard_Paused()` when paused for the given scope.
    /// @param target The `Pausable` contract controlling the global pause switch
    /// @param flags  A 16-bit mask encoding which features are gated by pause
    /// @param pauseBit The bit within `flags` that corresponds to the current operation's scope
    function checkNotPaused(Pausable target, Flags16 flags, uint16 pauseBit) internal view {
        if (isPaused(target, flags, pauseBit)) {
            revert Errors.LibPauseGuard_Paused();
        }
    }

    /// @notice Returns true if the pause is active and the `pauseBit` is set in `flags`.
    /// @param target The `Pausable` contract controlling the global pause switch
    /// @param flags  A 16-bit mask encoding which features are gated by pause
    /// @param pauseBit The bit within `flags` that corresponds to the current operation's scope
    function isPaused(Pausable target, Flags16 flags, uint16 pauseBit) internal view returns (bool) {
        return target.paused() && (Flags16.unwrap(flags) & pauseBit != 0);
    }
}
