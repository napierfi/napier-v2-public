// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {console2} from "forge-std/src/Test.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {EfficientHashLib} from "solady/src/utils/EfficientHashLib.sol";
import {LibBlueprint} from "src/utils/LibBlueprint.sol";

library SaltMiner {
    function findPrincipalTokenSalt(address factory, address msgSender, address blueprint)
        internal
        view
        returns (bytes32)
    {
        bytes32 initCodeHash = keccak256(LibBlueprint.extractCreationCode(blueprint));
        uint256 salt = uint256(keccak256(abi.encode(block.timestamp, msgSender)));
        while (true) {
            unchecked {
                salt++;
            }

            bytes32 safeSalt = EfficientHashLib.hash(block.chainid, uint256(uint160(msgSender)), uint256(salt));
            address predictedAddress = Create2.computeAddress(safeSalt, initCodeHash, factory);

            // Check if the address starts with 0xff
            if ((uint160(predictedAddress) >> 152) == 0xff) {
                console2.log("Salt found");
                console2.logBytes32(bytes32(salt));
                return bytes32(salt);
            }
        }
        revert("Salt not found");
    }

    function findPrincipalTokenSalt(address factory, address msgSender, address blueprint, address zap)
        internal
        view
        returns (bytes32)
    {
        bytes32 initCodeHash = keccak256(LibBlueprint.extractCreationCode(blueprint));
        uint256 salt = uint256(keccak256(abi.encode(block.timestamp, msgSender)));
        while (true) {
            unchecked {
                salt++;
            }

            address predictedAddress =
                predictPrincipalTokenAddress(bytes32(salt), initCodeHash, factory, msgSender, zap);

            // Check if the address starts with 0xff
            if ((uint160(predictedAddress) >> 152) == 0xff) {
                console2.log("Salt found");
                console2.logBytes32(bytes32(salt));
                return bytes32(salt);
            }
        }
        revert("Salt not found");
    }

    function predictPrincipalTokenAddress(
        bytes32 salt,
        bytes32 bytecodeHash,
        address factory,
        address msgSender,
        address zap
    ) internal view returns (address) {
        uint256 intermediate = uint256(EfficientHashLib.hash(uint256(uint160(msgSender)), uint256(salt)));
        bytes32 safeSalt = EfficientHashLib.hash(block.chainid, uint256(uint160(zap)), intermediate);
        return Create2.computeAddress(safeSalt, bytecodeHash, factory);
    }

    function predictPrincipalTokenAddress(address factory, address msgSender, bytes32 salt, address blueprint)
        internal
        view
        returns (address)
    {
        salt = EfficientHashLib.hash(block.chainid, uint256(uint160(msgSender)), uint256(salt));
        bytes32 bytecodeHash = keccak256(LibBlueprint.extractCreationCode(blueprint));
        return LibBlueprint.computeCreeate2Address(salt, bytecodeHash, factory);
    }
}
