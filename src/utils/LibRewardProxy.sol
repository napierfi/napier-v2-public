// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

// https://gist.github.com/Vectorized/ebb23b2b5395b6d6aa83fc36af98a18c

import {TokenReward} from "../Types.sol";

library LibRewardProxy {
    function delegateCallCollectReward(address rewardProxy) internal returns (TokenReward[] memory rewards) {
        assembly {
            mstore(0x14, rewardProxy) // Store the argument.
            mstore(0x00, 0x82c97b8d000000000000000000000000) // `collectReward(address)`.
            if iszero(delegatecall(gas(), rewardProxy, 0x10, 0x24, codesize(), 0x00)) {
                mstore(0x00, 0x3f12e961) // `PrincipalToken_CollectRewardFailed()`
                revert(0x1c, 0x04)
            }

            let m := mload(0x40) // Grab the free memory pointer.
            returndatacopy(m, 0x00, returndatasize()) // Just copy all of the return data.

            let t := add(m, mload(m)) // Pointer to `rewards` in the returndata.
            let n := mload(t) // `rewards.length`.
            let r := add(t, 0x20) // Pointer to `rewards[0]` in the returndata.

            // Skip the copied data.
            // We will initialize rewards as an array of pointers into the copied data.
            let a := add(m, returndatasize())
            if or(shr(64, mload(m)), or(lt(returndatasize(), 0x20), gt(add(r, shl(6, n)), a))) {
                revert(codesize(), 0x00)
            }

            if n {
                mstore(a, n) // Store the length of the array.
                let o := add(a, 0x20)
                mstore(0x40, add(o, shl(5, n))) // Allocate the memory.
                rewards := a
                for { let i := 0 } 1 {} {
                    let p := add(r, shl(6, i))
                    // Revert if the `rewards[i].token` has dirty upper bits.
                    if shr(160, mload(p)) { revert(codesize(), 0x00) }
                    mstore(add(o, shl(5, i)), p)
                    i := add(i, 1)
                    if eq(i, n) { break }
                }
            }
        }
    }
}
