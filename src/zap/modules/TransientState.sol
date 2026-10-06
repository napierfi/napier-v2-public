// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LibTransient} from "solady/src/utils/LibTransient.sol";

library TransientState {
    using LibTransient for LibTransient.TAddress;
    using LibTransient for LibTransient.TBytes;

    /// @dev The slot of a temporary pool key created by the sender
    bytes32 private constant _TRANSIENT_POOL_KEY_SLOT_SEED = bytes32(uint256(0xaead0cc698843ef970));
    /// @dev Slot for the callback authorization
    bytes32 private constant _TRANSIENT_CALLBACKER_SLOT_SEED = bytes32(uint256(0x30a528300a71392643));

    function setPoolKey(PoolKey memory key) internal {
        bytes memory value = abi.encode(key);
        LibTransient.tBytes(_TRANSIENT_POOL_KEY_SLOT_SEED).set(value);
    }

    function getPoolKey() internal view returns (PoolKey memory key) {
        bytes memory value = LibTransient.tBytes(_TRANSIENT_POOL_KEY_SLOT_SEED).get();
        key = abi.decode(value, (PoolKey));
    }

    /// @notice Set the callback authorization address
    /// @param callbacker The address authorized to make callbacks
    function setCallbacker(address callbacker) internal {
        LibTransient.tAddress(_TRANSIENT_CALLBACKER_SLOT_SEED).set(callbacker);
    }

    /// @notice Get and clear the callback authorization address
    /// @return callbacker The authorized callback address
    function getAndClearCallbacker() internal returns (address callbacker) {
        callbacker = LibTransient.tAddress(_TRANSIENT_CALLBACKER_SLOT_SEED).get();
        LibTransient.tAddress(_TRANSIENT_CALLBACKER_SLOT_SEED).clear();
    }
}
