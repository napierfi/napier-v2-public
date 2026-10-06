// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Uint128x2} from "../Types.sol";

library Packing {
    using Packing for *;

    function unwrap(Uint128x2 packed) internal pure returns (uint256) {
        return Uint128x2.unwrap(packed);
    }

    function unpack(Uint128x2 packed) internal pure returns (uint128 _value0, uint128 _value1) {
        /// @solidity memory-safe-assembly
        assembly {
            _value0 := shr(128, packed)
            _value1 := and(shr(128, not(0)), packed)
        }
    }

    /// @dev Clean dirt bits from `a` and `b`.
    function pack_uint128x2(uint128 a, uint128 b) internal pure returns (Uint128x2 packed) {
        /// @solidity memory-safe-assembly
        assembly {
            packed := or(shl(128, a), and(b, shr(128, not(0))))
        }
    }

    function add(Uint128x2 a, uint128 v1, uint128 v2) internal pure returns (Uint128x2) {
        return radd(a, pack_uint128x2(v1, v2));
    }

    function radd(Uint128x2 a, Uint128x2 b) internal pure returns (Uint128x2 c) {
        // Just adding uint128-bits values together
        c = Uint128x2.wrap(a.unwrap() + b.unwrap());

        // On overflow c will be less than either a or b
        // Type cast c to uint128 to isolate the right value and if it's lower than a value it's comprised of (a)
        // then an overflow has occurred
        if (c.unwrap() < a.unwrap() || (uint128(c.unwrap()) < uint128(a.unwrap()))) _revertOverflow();
    }

    function sub(Uint128x2 a, uint128 v1, uint128 v2) internal pure returns (Uint128x2) {
        (uint128 _value0, uint128 _value1) = unpack(a);
        return pack_uint128x2(_value0 - v1, _value1 - v2);
    }

    function value0(Uint128x2 a) internal pure returns (uint128 _value0) {
        /// @solidity memory-safe-assembly
        assembly {
            _value0 := shr(128, a)
        }
    }

    function value1(Uint128x2 a) internal pure returns (uint128 _value1) {
        /// @solidity memory-safe-assembly
        assembly {
            _value1 := and(shr(128, not(0)), a)
        }
    }

    function _revertOverflow() private pure {
        /// @solidity memory-safe-assembly
        assembly {
            // Store the function selector of `Overflow()`.
            mstore(0x00, 0x35278d12)
            // Revert with (offset, size).
            revert(0x1c, 0x04)
        }
    }
}
