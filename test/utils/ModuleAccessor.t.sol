// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {ModuleIndex, FEE_MODULE_INDEX, REWARD_PROXY_MODULE_INDEX, VERIFIER_MODULE_INDEX} from "src/Types.sol";
import {SSTORE2} from "solady/src/utils/SSTORE2.sol";

import {ModuleAccessor} from "src/utils/ModuleAccessor.sol";
import "src/Constants.sol" as Constants;

contract ModuleAccessorTest is Test {
    function test_Read() public {
        address[] memory modules = new address[](3);
        modules[0] = makeAddr("shika");
        modules[1] = makeAddr("noko");
        modules[2] = makeAddr("nokonoko");

        testFuzz_Read(modules);
    }

    function testFuzz_Read(address[] memory modules) public {
        address pointer = SSTORE2.write(abi.encode(modules));
        address[] memory m = ModuleAccessor.read(pointer);
        assertEq(m.length, modules.length, "length");
        for (uint256 i = 0; i < modules.length; i++) {
            assertEq(m[i], modules[i], string.concat("member_", vm.toString(i)));
        }
    }

    function testFuzz_Get(address[] memory m) public pure {
        for (uint256 i = 0; i < m.length; i++) {
            assertEq(ModuleAccessor.get(m, ModuleIndex.wrap(i)), m[i], "get(i)");
        }
    }

    function testFuzz_UnsafeGet(address[] memory m) public pure {
        for (uint256 i = 0; i < m.length; i++) {
            assertEq(ModuleAccessor.unsafeGet(m, ModuleIndex.wrap(i)), m[i], "unsafeGet(i)");
        }
    }

    function testFuzz_GetOrDefault(address[] memory m) public pure {
        for (uint256 i = 0; i < m.length + 10; i++) {
            if (i < m.length) {
                assertEq(ModuleAccessor.getOrDefault(m, ModuleIndex.wrap(i)), m[i], "getOrDefault(i)");
            } else {
                assertEq(ModuleAccessor.getOrDefault(m, ModuleIndex.wrap(i)), address(0), "getOrDefault(i) == 0");
            }
        }
    }

    function testFuzz_Set(address[] memory m) public pure {
        for (uint256 i = 0; i < m.length; i++) {
            address newValue = address(uint160(uint256(keccak256(abi.encodePacked(m[i])))));
            ModuleAccessor.set(m, ModuleIndex.wrap(i), newValue);
            assertEq(ModuleAccessor.get(m, ModuleIndex.wrap(i)), newValue, "set(i)");
        }
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_Get_RevertWhen_OutOfBounds() public {
        vm.expectRevert(ModuleAccessor.ModuleOutOfBounds.selector);
        ModuleAccessor.get(new address[](1), ModuleIndex.wrap(1));
        vm.expectRevert(ModuleAccessor.ModuleOutOfBounds.selector);
        ModuleAccessor.get(new address[](1), ModuleIndex.wrap(2));
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_Set_RevertWhen_OutOfBounds() public {
        vm.expectRevert(ModuleAccessor.ModuleOutOfBounds.selector);
        ModuleAccessor.set(new address[](1), ModuleIndex.wrap(1), makeAddr("shika"));
        vm.expectRevert(ModuleAccessor.ModuleOutOfBounds.selector);
        ModuleAccessor.set(new address[](1), ModuleIndex.wrap(2), makeAddr("shika"));
    }

    function testGas_Read() public {
        address[] memory accounts = new address[](6);
        accounts[0] = makeAddr("shika");
        accounts[1] = makeAddr("noko");
        accounts[2] = makeAddr("nokonoko");
        accounts[3] = makeAddr("koshi");
        accounts[5] = makeAddr("tantan");

        address pointer = SSTORE2.write(abi.encode(accounts));

        uint256 gas = gasleft();
        address[] memory m = ModuleAccessor.read(pointer);
        ModuleAccessor.get(m, FEE_MODULE_INDEX);
        ModuleAccessor.get(m, REWARD_PROXY_MODULE_INDEX);
        ModuleAccessor.get(m, VERIFIER_MODULE_INDEX);
        console2.log("gas", gas - gasleft());
    }
}
