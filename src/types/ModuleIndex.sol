// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {ModuleIndex, MAX_MODULES} from "../Types.sol";

function unwrap(ModuleIndex x) pure returns (uint256 result) {
    result = ModuleIndex.unwrap(x);
}

/// @dev Checks if the given module index is supported by Factory.
/// @dev Even if Factory supports the module, Principal Token instance may not support it due to the length of the array mismatch.
function isSupportedByFactory(ModuleIndex x) pure returns (bool result) {
    result = ModuleIndex.unwrap(x) < MAX_MODULES;
}

function eq(ModuleIndex x, ModuleIndex y) pure returns (bool result) {
    result = ModuleIndex.unwrap(x) == ModuleIndex.unwrap(y);
}
