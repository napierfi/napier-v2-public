// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {LibBytes} from "solady/src/utils/LibBytes.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";

library LibBlueprint {
    using SafeCastLib for uint256;

    error DeploymentFailed();
    error InvalidBlueprint();

    /// @dev Deploy contract from blueprint using CREATE
    /// @param _blueprint Address of the blueprint contract
    /// @return The address of the deployed contract
    function create(address _blueprint) internal returns (address) {
        return _create(_blueprint, "");
    }

    /// @dev Return address(0) if deployment fails
    function tryCreate(address _blueprint, bytes memory args) internal returns (address deployed) {
        bytes memory initcode = extractCreationCode(_blueprint);
        // Combine initcode with constructor arguments
        bytes memory deployCode = LibBytes.concat(initcode, args);

        // Deploy the contract
        assembly {
            deployed := create(0, add(deployCode, 32), mload(deployCode))
        }
    }

    /// @dev Deploy contract from blueprint using CREATE with constructor arguments
    /// @param _blueprint Address of the blueprint contract
    /// @param args Constructor arguments
    /// @return The address of the deployed contract
    function create(address _blueprint, bytes memory args) internal returns (address) {
        return _create(_blueprint, args);
    }

    /// @dev Deploy contract from blueprint using CREATE2
    /// @param _blueprint Address of the blueprint contract
    /// @param salt Unique salt for deterministic addressing
    /// @return The address of the deployed contract
    function create2(address _blueprint, bytes32 salt) internal returns (address) {
        return _create2(_blueprint, "", salt);
    }

    /// @dev Deploy contract from blueprint using CREATE2 with constructor arguments
    /// @param _blueprint Address of the blueprint contract
    /// @param args Constructor arguments
    /// @param salt Unique salt for deterministic addressing
    /// @return The address of the deployed contract
    function create2(address _blueprint, bytes memory args, bytes32 salt) internal returns (address) {
        return _create2(_blueprint, args, salt);
    }

    /// @dev Encode bytecode into blueprint format
    /// @param initcode The original contract bytecode
    /// @return The encoded blueprint bytecode
    function blueprint(bytes memory initcode) internal pure returns (bytes memory) {
        bytes memory blueprint_bytecode = bytes.concat(
            hex"fe", // EIP_5202_EXECUTION_HALT_BYTE
            hex"71", // EIP_5202_BLUEPRINT_IDENTIFIER_BYTE
            hex"00", // EIP_5202_VERSION_BYTE
            initcode
        );
        bytes2 len = bytes2(blueprint_bytecode.length.toUint16());

        bytes memory deployBytecode = bytes.concat(
            hex"61", // DEPLOY_PREAMBLE_INITIAL_BYTE
            len, // DEPLOY_PREAMBLE_BYTE_LENGTH
            hex"3d81600a3d39f3", // DEPLOY_PREABLE_POST_LENGTH_BYTES
            blueprint_bytecode
        );

        return deployBytecode;
    }

    /// @dev Deploy blueprint contract
    /// @param initcode The original contract bytecode
    /// @return deployed The address of the deployed blueprint contract
    function deployBlueprint(bytes memory initcode) internal returns (address deployed) {
        bytes memory deployBytecode = blueprint(initcode);

        assembly {
            deployed := create(0, add(deployBytecode, 0x20), mload(deployBytecode))
        }

        if (deployed == address(0)) revert DeploymentFailed();
    }

    // Internal helper functions
    function _create(address _blueprint, bytes memory args) private returns (address deployed) {
        bytes memory initcode = extractCreationCode(_blueprint);
        // Combine initcode with constructor arguments
        bytes memory deployCode = LibBytes.concat(initcode, args);

        // Deploy the contract
        assembly {
            deployed := create(0, add(deployCode, 32), mload(deployCode))
        }

        if (deployed == address(0)) revert DeploymentFailed();
    }

    function _create2(address _blueprint, bytes memory args, bytes32 salt) private returns (address deployed) {
        bytes memory initcode = extractCreationCode(_blueprint);
        // Combine initcode with constructor arguments
        bytes memory deployCode = LibBytes.concat(initcode, args);

        // Deploy the contract using CREATE2
        assembly {
            deployed := create2(0, add(deployCode, 32), mload(deployCode), salt)
        }

        if (deployed == address(0)) revert DeploymentFailed();
    }

    function extractCreationCode(address _blueprint) private view returns (bytes memory initcode) {
        uint256 size;
        uint256 offset = 3; // Skip first 3 bytes

        assembly {
            size := extcodesize(_blueprint)
        }

        // Check if there's any code after the offset
        if (size <= offset) {
            revert InvalidBlueprint();
        }

        // Extract the initcode
        uint256 initcodeSize = size - offset;
        initcode = new bytes(initcodeSize);

        assembly {
            extcodecopy(_blueprint, add(initcode, 32), offset, initcodeSize)
        }
    }

    function computeCreate2Address(bytes32 salt, address _blueprint, bytes memory args)
        internal
        view
        returns (address)
    {
        bytes32 bytecodeHash = keccak256(LibBytes.concat(extractCreationCode(_blueprint), args));
        return computeCreeate2Address(salt, bytecodeHash, address(this));
    }

    function computeCreeate2Address(bytes32 salt, bytes32 bytecodeHash, address deployer)
        internal
        pure
        returns (address addr)
    {
        /// @solidity memory-safe-assembly
        assembly {
            let ptr := mload(0x40) // Get free memory pointer

            mstore(add(ptr, 0x40), bytecodeHash)
            mstore(add(ptr, 0x20), salt)
            mstore(ptr, deployer) // Right-aligned with 12 preceding garbage bytes
            let start := add(ptr, 0x0b) // The hashed data starts at the final garbage byte which we will set to 0xff
            mstore8(start, 0xff)
            addr := keccak256(start, 85)
        }
    }
}
