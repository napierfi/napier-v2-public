// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import {LibBytes} from "solady/src/utils/LibBytes.sol";

import "../Types.sol";

/// @notice Encoding utilities for hooks of Zap
library ZapHookEncoder {
    /// @notice abi.encode(twoCrypto, underlying, by, sharesFromUser)
    /// @notice Encode the data for the `swapTokenForYt`'s supply hook
    function encodeSupply(TwoCrypto twoCrypto, address underlying, address by, uint256 sharesFromUser)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory data = new bytes(0x80);
        assembly {
            mstore(add(data, 0x20), twoCrypto)
            mstore(add(data, 0x40), underlying)
            mstore(add(data, 0x60), by)
            mstore(add(data, 0x80), sharesFromUser)
        }
        return data;
    }

    function decodeSupply(bytes calldata data)
        internal
        pure
        returns (TwoCrypto twoCrypto, address underlying, address by, uint256 sharesFromUser)
    {
        twoCrypto = TwoCrypto.wrap(address(uint160(uint256(LibBytes.loadCalldata(data, 0x00)))));
        underlying = address(uint160(uint256(LibBytes.loadCalldata(data, 0x20))));
        by = address(uint160(uint256(LibBytes.loadCalldata(data, 0x40))));
        sharesFromUser = uint256(LibBytes.loadCalldata(data, 0x60));
    }

    /// @notice abi.encode(twoCrypto, underlying, sharesDx)
    /// @notice Encode the data for the `swapYtForToken`'s unite hook
    function encodeUnite(TwoCrypto twoCrypto, address underlying, ApproxValue sharesDx)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory data = new bytes(0x60);
        assembly {
            mstore(add(data, 0x20), twoCrypto)
            mstore(add(data, 0x40), underlying)
            mstore(add(data, 0x60), sharesDx)
        }
        return data;
    }

    function decodeUnite(bytes calldata data)
        internal
        pure
        returns (TwoCrypto twoCrypto, address underlying, uint256 sharesDx)
    {
        twoCrypto = TwoCrypto.wrap(address(uint160(uint256(LibBytes.loadCalldata(data, 0x00)))));
        underlying = address(uint160(uint256(LibBytes.loadCalldata(data, 0x20))));
        sharesDx = uint256(LibBytes.loadCalldata(data, 0x40));
    }
}
