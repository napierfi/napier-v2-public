// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "src/Constants.sol" as Constants;
import {Factory} from "src/Factory.sol";

/// @notice A mock factory for testing purposes.
contract MockFactory {
    uint256 public constant DEFAULT_SPLIT_RATIO_BPS = Constants.DEFAULT_SPLIT_RATIO_BPS;

    address public immutable i_accessManager;
    Factory.ConstructorArg s_args;
    address public s_treasury;

    constructor(address _accessManager) {
        i_accessManager = _accessManager;
    }

    function setArgs(Factory.ConstructorArg memory _args) external {
        s_args = _args;
    }

    function deploy(bytes memory initCode, bytes32 salt) external returns (address pt) {
        assembly {
            pt := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(pt != address(0), "MockFactory: Failed to deploy");
    }

    function setTreasury(address treasury) external {
        s_treasury = treasury;
    }

    function args() external view returns (Factory.ConstructorArg memory) {
        return s_args;
    }
}
