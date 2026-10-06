// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @dev Modified from: https://github.com/Uniswap/universal-router/blob/3663f6db6e2fe121753cd2d899699c2dc75dca86/contracts/UniversalRouter.sol
/// CHANGES:
/// - Rename file and variables
/// - Some error messages are changed
/// - Modify receive() function to allow receiving ETH from Napier related contracts

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {
    PaymentsImmutables, PaymentsParameters
} from "@uniswap/universal-router/contracts/modules/PaymentsImmutables.sol";
import {V4SwapRouter} from "../modules/v4-periphery/V4SwapRouter.sol";
import {NapierV2Immutables} from "../modules/NapierV2Immutables.sol";
import {Commands} from "./Commands.sol";
import {CustomRevert} from "../../utils/CustomRevert.sol";

// Interfaces
import "../../Types.sol";
import "../../Errors.sol";

// Inherits
import {Dispatcher} from "./Dispatcher.sol";

contract UniswapV4Router is Dispatcher {
    using CustomRevert for *;

    error LengthMismatch();
    error ExecutionFailed(uint256 commandIndex, bytes message);

    constructor(IPoolManager v4PoolManager, address permit2, address weth9, NapierV2Parameters memory params)
        V4SwapRouter(address(v4PoolManager))
        PaymentsImmutables(PaymentsParameters(permit2, weth9))
        NapierV2Immutables(params)
    {}

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) Errors.Zap_TransactionTooOld.selector.revertWith();
        _;
    }

    /// @dev Allow receiving ETH from any address
    receive() external payable {}

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
    {
        execute(commands, inputs);
    }

    function execute(bytes calldata commands, bytes[] calldata inputs) public payable override isNotLocked {
        bool success;
        bytes memory output;
        uint256 numCommands = commands.length;
        if (inputs.length != numCommands) LengthMismatch.selector.revertWith();

        // loop through all given commands, execute them and pass along outputs as defined
        for (uint256 commandIndex = 0; commandIndex < numCommands; commandIndex++) {
            bytes1 command = commands[commandIndex];

            bytes calldata input = inputs[commandIndex];

            (success, output) = dispatch(command, input);

            if (!success && successRequired(command)) {
                revert ExecutionFailed({commandIndex: commandIndex, message: output});
            }
        }
    }

    function successRequired(bytes1 command) internal pure returns (bool) {
        return command & Commands.FLAG_ALLOW_REVERT == 0;
    }
}
