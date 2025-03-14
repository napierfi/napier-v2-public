// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {SSTORE2} from "solady/src/utils/SSTORE2.sol";
import {ModuleIndex} from "../Types.sol";

library ModuleAccessor {
    error ModuleOutOfBounds();

    function read(address pointer) internal view returns (address[] memory m) {
        // The first 32 bytes of the data is the offset to the start of the contents of the `data`. 0x20 is expected here.
        // The contents of the `data` is an address[] array.
        bytes memory data = SSTORE2.read(pointer);
        assembly {
            m := add(data, 0x40) // Grab the encoded array
        }
    }

    /// @notice Get a module address by index.
    /// @dev Note: The module index is zero-based. Reverts with ModuleOutOfBounds if index is out of range.
    function get(address[] memory m, ModuleIndex idx) internal pure returns (address module) {
        assembly {
            if iszero(lt(idx, mload(m))) {
                mstore(0x00, 0x13bec8a3) // `ModuleOutOfBounds()`.
                revert(0x1c, 0x04)
            }
            module := mload(add(add(m, 0x20), mul(idx, 0x20)))
        }
    }

    function unsafeGet(address[] memory m, ModuleIndex idx) internal pure returns (address module) {
        assembly {
            module := mload(add(add(m, 0x20), mul(idx, 0x20)))
        }
    }

    function getOrDefault(address[] memory m, ModuleIndex idx) internal pure returns (address module) {
        assembly {
            if lt(idx, mload(m)) { module := mload(add(add(m, 0x20), mul(idx, 0x20))) }
        }
    }

    /// @notice Replace a module address by index.
    function set(address[] memory m, ModuleIndex idx, address module) internal pure {
        assembly {
            if iszero(lt(idx, mload(m))) {
                mstore(0x00, 0x13bec8a3) // `ModuleOutOfBounds()`.
                revert(0x1c, 0x04)
            }
            mstore(add(add(m, 0x20), mul(idx, 0x20)), module)
        }
    }
}
