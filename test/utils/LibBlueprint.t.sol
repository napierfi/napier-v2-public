// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {LibBlueprint} from "src/utils/LibBlueprint.sol";
import {CREATE3} from "solady/src/utils/CREATE3.sol";

contract MockContract {
    uint256 public value;

    constructor(uint256 _value) {
        value = _value;
    }
}

contract LibBlueprintTest is Test {
    using LibBlueprint for address;

    function testFuzz_Blueprint(bytes memory initcode) public pure {
        bytes memory deployBytecode = LibBlueprint.blueprint(initcode);

        // Check deploy preamble
        assertEq(deployBytecode[0], bytes1(0x61), "Invalid deploy preamble initial byte");

        // Extract length
        uint16 encodedLength = uint16(bytes2(deployBytecode[1]) | (bytes2(deployBytecode[2]) >> 8));

        // Check deploy preamble post length bytes
        assertEq(deployBytecode[3], bytes1(0x3d), "Invalid deploy preamble post length byte 1");
        assertEq(deployBytecode[4], bytes1(0x81), "Invalid deploy preamble post length byte 2");
        assertEq(deployBytecode[5], bytes1(0x60), "Invalid deploy preamble post length byte 3");
        assertEq(deployBytecode[6], bytes1(0x0a), "Invalid deploy preamble post length byte 4");
        assertEq(deployBytecode[7], bytes1(0x3d), "Invalid deploy preamble post length byte 5");
        assertEq(deployBytecode[8], bytes1(0x39), "Invalid deploy preamble post length byte 6");
        assertEq(deployBytecode[9], bytes1(0xf3), "Invalid deploy preamble post length byte 7");

        // Check EIP-5202 prefix
        assertEq(deployBytecode[10], bytes1(0xfe), "Invalid EIP-5202 execution halt byte");
        assertEq(deployBytecode[11], bytes1(0x71), "Invalid EIP-5202 blueprint identifier byte");
        assertEq(deployBytecode[12], bytes1(0x00), "Invalid EIP-5202 version byte");

        // Check that the initcode is correctly appended
        for (uint256 i = 0; i < initcode.length; i++) {
            assertEq(deployBytecode[i + 13], initcode[i], "Initcode mismatch");
        }

        // Check total length
        uint16 expectedEncodedLength = uint16(3 + initcode.length); // 3 bytes of EIP-5202 prefix + initcode length
        assertEq(encodedLength, expectedEncodedLength, "Invalid length in deploy bytecode");
        assertEq(deployBytecode.length, 10 + encodedLength, "Invalid total length"); // 10 bytes of preamble + encoded length
    }

    function testFuzz_DeployBlueprint(uint256 value) public {
        bytes memory initcode = abi.encodePacked(type(MockContract).creationCode, abi.encode(value));
        address blueprintAddress = LibBlueprint.deployBlueprint(initcode);
        assertTrue(blueprintAddress != address(0), "Blueprint deployment failed");

        bytes memory blueprintCode = address(blueprintAddress).code;
        assertEq(blueprintCode[0], bytes1(0xfe), "Invalid EIP-5202 execution halt byte");
        assertEq(blueprintCode[1], bytes1(0x71), "Invalid EIP-5202 blueprint identifier byte");
        assertEq(blueprintCode[2], bytes1(0x00), "Invalid EIP-5202 version byte");
    }

    function testFuzz_Create(uint256 value) public {
        bytes memory initcode = abi.encodePacked(type(MockContract).creationCode, abi.encode(value));
        address blueprintAddress = LibBlueprint.deployBlueprint(initcode);

        address deployedAddress = blueprintAddress.create();
        assertTrue(deployedAddress != address(0), "Contract deployment failed");

        MockContract deployedContract = MockContract(deployedAddress);
        assertEq(deployedContract.value(), value, "Deployed contract has incorrect value");
    }

    function testFuzz_CreateWithArgs(uint256 value) public {
        bytes memory initcode = type(MockContract).creationCode;
        address blueprintAddress = LibBlueprint.deployBlueprint(initcode);

        bytes memory args = abi.encode(value);
        address deployedAddress = blueprintAddress.create(args);
        assertTrue(deployedAddress != address(0), "Contract deployment failed");

        MockContract deployedContract = MockContract(deployedAddress);
        assertEq(deployedContract.value(), value, "Deployed contract has incorrect value");
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testFuzz_Create2WithArgsAndAddressPrediction(uint256 value, bytes32 salt) public {
        bytes memory initcode = type(MockContract).creationCode;
        address blueprintAddress = LibBlueprint.deployBlueprint(initcode);

        bytes memory args = abi.encode(value);

        // Predict the address
        address predictedAddress = LibBlueprint.computeCreate2Address(salt, blueprintAddress, args);

        // Deploy the contract
        address deployedAddress = LibBlueprint.create2(blueprintAddress, args, salt);

        // Check if the deployed address matches the predicted address
        assertEq(deployedAddress, predictedAddress, "Deployed address does not match predicted address");

        // Check if the contract was deployed correctly
        assertTrue(deployedAddress != address(0), "Contract deployment failed");
        MockContract deployedContract = MockContract(deployedAddress);
        assertEq(deployedContract.value(), value, "Deployed contract has incorrect value");

        // Try to deploy again with the same salt (should fail)
        vm.expectRevert();
        LibBlueprint.create2(blueprintAddress, args, salt);
    }
}
