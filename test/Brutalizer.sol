// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

/// @dev Forked from https://github.com/Vectorized/solady/blob/45bba1221ad451289d2f54c2f7f48aea624e17aa/test/utils/Brutalizer.sol
/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract Brutalizer {
    /// @dev Fills the memory with junk, for more robust testing of inline assembly
    /// which reads/write to the memory.
    modifier brutalizeMemory() {
        _brutalizeMemory();
        _;
        _checkMemory();
    }

    /// @dev Multiplier for a mulmod Lehmer psuedorandom number generator.
    /// Prime, and a primitive root of `_LPRNG_MODULO`.
    uint256 private constant _LPRNG_MULTIPLIER = 0x100000000000000000000000000000051;

    /// @dev Modulo for a mulmod Lehmer psuedorandom number generator. (prime)
    uint256 private constant _LPRNG_MODULO = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff43;

    /// @dev Fills the memory with junk, for more robust testing of inline assembly
    /// which reads/write to the memory.
    function _brutalizeMemory() internal view {
        // To prevent a solidity 0.8.13 bug.
        // See: https://blog.soliditylang.org/2022/06/15/inline-assembly-memory-side-effects-bug
        // Basically, we need to access a solidity variable from the assembly to
        // tell the compiler that this assembly block is not in isolation.
        uint256 zero;
        /// @solidity memory-safe-assembly
        assembly {
            let offset := mload(0x40) // Start the offset at the free memory pointer.
            calldatacopy(add(offset, 0x20), zero, calldatasize())
            mstore(offset, add(caller(), gas()))

            // Fill the 64 bytes of scratch space with garbage.
            let r := keccak256(offset, add(calldatasize(), 0x40))
            mstore(zero, r)
            mstore(0x20, keccak256(zero, 0x40))
            r := mulmod(mload(0x10), _LPRNG_MULTIPLIER, _LPRNG_MODULO)

            let cSize := add(codesize(), iszero(codesize()))
            if iszero(lt(cSize, 32)) { cSize := sub(cSize, and(mload(0x02), 0x1f)) }
            let start := mod(mload(0x10), cSize)
            let size := mul(sub(cSize, start), gt(cSize, start))
            let times := div(0x7ffff, cSize)
            if iszero(lt(times, 128)) { times := 128 }

            // Occasionally offset the offset by a pseudorandom large amount.
            // Can't be too large, or we will easily get out-of-gas errors.
            offset := add(offset, mul(iszero(and(r, 0xf00000000)), and(shr(64, r), 0xfffff)))

            // Fill the free memory with garbage.
            // prettier-ignore
            for { let w := not(0) } 1 {} {
                mstore(offset, mload(0x00))
                mstore(add(offset, 0x20), mload(0x20))
                offset := add(offset, 0x40)
                // We use codecopy instead of the identity precompile
                // to avoid polluting the `forge test -vvvv` output with tons of junk.
                codecopy(offset, start, size)
                codecopy(add(offset, size), 0x00, start)
                offset := add(offset, cSize)
                times := add(times, w) // `sub(times, 1)`.
                if iszero(times) { break }
            }
            // With a 1/16 chance, copy the contract's code to the scratch space.
            if iszero(and(0xf00, r)) {
                codecopy(0x00, mod(shr(128, r), add(codesize(), codesize())), 0x40)
                mstore8(and(r, 0x3f), iszero(and(0x100000, r)))
            }
        }
    }

    /// @dev Check if the free memory pointer and the zero slot are not contaminated.
    /// Useful for cases where these slots are used for temporary storage.
    function _checkMemory() internal pure {
        bool zeroSlotIsNotZero;
        bool freeMemoryPointerOverflowed;
        /// @solidity memory-safe-assembly
        assembly {
            // Write ones to the free memory, to make subsequent checks fail if
            // insufficient memory is allocated.
            mstore(mload(0x40), not(0))
            // Test at a lower, but reasonable limit for more safety room.
            if gt(mload(0x40), 0xffffffff) { freeMemoryPointerOverflowed := 1 }
            // Check the value of the zero slot.
            zeroSlotIsNotZero := mload(0x60)
        }
        if (freeMemoryPointerOverflowed) revert("`0x40` overflowed!");
        if (zeroSlotIsNotZero) revert("`0x60` is not zero!");
    }
}
