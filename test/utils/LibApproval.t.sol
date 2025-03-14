// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {LibApproval} from "src/utils/LibApproval.sol";

contract LibApprovalTest is LibApproval, Test {
    function test_Seed() public pure {
        assertEq(_IS_APPROVED_SLOT_SEED, uint256(uint32(bytes4(keccak256("_IS_APPROVED_SLOT_SEED")))));
    }

    function testFuzz_Slot(address src, address spender) public {
        // keccak256(`src` . 16 zeros . `slot seed` . `spender`) where . is concatenation.
        bytes memory preimage = abi.encodePacked(src, uint64(0), uint32(_IS_APPROVED_SLOT_SEED), spender);
        bytes32 slot = keccak256(preimage);
        vm.store(address(this), slot, bytes32(uint256(1)));
        assertEq(isApproved(src, spender), true);
    }

    function testFuzz_setApproval(address src, address spender) public {
        bool approved; // non-zero random `true`-ish value
        assembly {
            mstore(0x00, src)
            mstore(0x20, spender)
            approved := keccak256(0x00, 0x40)
        }
        vm.assume(approved);

        assertEq(isApproved(src, spender), false);
        setApproval(src, spender, approved);
        assertEq(isApproved(src, spender), true);

        setApproval(src, spender, !approved);
        assertEq(isApproved(src, spender), false);
    }
}
