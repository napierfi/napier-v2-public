// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @dev Modified from: https://github.com/Uniswap/universal-router/blob/3663f6db6e2fe121753cd2d899699c2dc75dca86/contracts/base/Dispatcher.sol
/// CHANGES:
/// - Uniswap V2 and V3 swap commands are completely removed
/// - Uniswap V4 swap commands are left as is
/// - Support Napier V2 commands

import "../../Types.sol";
import "../../Errors.sol";
import {Commands} from "./Commands.sol";
import {PrincipalToken} from "../../tokens/PrincipalToken.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {CalldataDecoder} from "@uniswap/v4-periphery/src/libraries/CalldataDecoder.sol";
import {BytesLib} from "@uniswap/universal-router/contracts/modules/uniswap/v3/BytesLib.sol";
import {IAllowanceTransfer} from "@uniswap/universal-router/contracts/modules/Permit2Payments.sol";
import {BaseActionsRouter} from "@uniswap/v4-periphery/src/base/BaseActionsRouter.sol";

import {Factory} from "../../Factory.sol";

// Inherits
import {Lock} from "@uniswap/universal-router/contracts/base/Lock.sol";
import {Payments} from "@uniswap/universal-router/contracts/modules/Payments.sol";
import {V4SwapRouter} from "../modules/v4-periphery/V4SwapRouter.sol";

import {VaultConnectorRouter} from "../modules/VaultConnectorRouter.sol";
import {PrincipalTokenRouter} from "../modules/PrincipalTokenRouter.sol";
import {TokiPoolRouter} from "../modules/TokiPoolRouter.sol";
import {SwapAggregatorRouter} from "../modules/SwapAggregatorRouter.sol";
import {RouterPayload} from "../../modules/aggregator/AggregationRouter.sol";
import {V4Permit2Payments} from "../modules/V4Permit2Payments.sol";
import {CustomRevert} from "../../utils/CustomRevert.sol";

/// @dev Commands are executed in sequence and can be chained for complex operations
///
/// SUPPORTED ACTIONS:
/// - Liquidity Management: Add/remove liquidity proportionally to TokiPools
/// - Principal/Yield Tokens: Issue PT/YT, redeem PT, combine PT+YT back to underlying
/// - External Integrations: Aggregator swaps, connector deposits/redemptions
/// - Token Operations: Split underlying tokens, V4 swaps (exact input/output)
/// - Utility: Take, settle, sweep operations for balance management
/// - Pool Creation: Create pools and add initial liquidity with optional wrappers
///
/// WORKFLOW EXAMPLES:
///
/// @dev Keep-YT Liquidity Addition:
///      ETH → wstETH (connector) → split tokens → issue PT → add liquidity → sweep YT
///
/// @dev No-YT Liquidity Addition:
///      ETH → underlying (connector) → swap some of it to PT → add liquidity
abstract contract Dispatcher is
    Payments,
    V4SwapRouter,
    VaultConnectorRouter,
    PrincipalTokenRouter,
    TokiPoolRouter,
    SwapAggregatorRouter,
    Lock
{
    using BytesLib for bytes;
    using CalldataDecoder for bytes;
    using CustomRevert for *;

    error InvalidCommandType(uint256 commandType);
    error BalanceTooLow();

    /// @notice Executes encoded commands along with provided inputs.
    /// @param commands A set of concatenated commands, each 1 byte in length
    /// @param inputs An array of byte strings containing abi encoded inputs for each command
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable virtual;

    /// @notice Public view function to be used instead of msg.sender, as the contract performs self-reentrancy and at
    /// times msg.sender == address(this). Instead msgSender() returns the initiator of the lock
    /// @dev overrides BaseActionsRouter.msgSender in V4Router
    function msgSender() public view override(BaseActionsRouter, V4Permit2Payments) returns (address) {
        return _getLocker();
    }

    /// @notice Decodes and executes the given command with the given inputs
    /// @param commandType The command type to execute
    /// @param inputs The inputs to execute the command with
    /// @dev 2 masks are used to enable use of a nested-if statement in execution for efficiency reasons
    /// @return success True on success of the command, false on failure
    /// @return output The outputs or error messages, if any, from the command
    function dispatch(bytes1 commandType, bytes calldata inputs) internal returns (bool success, bytes memory output) {
        uint256 command = uint8(commandType & Commands.COMMAND_TYPE_MASK);

        success = true;

        // 0x00 <= command < 0x21
        if (command < Commands.EXECUTE_SUB_PLAN) {
            // 0x00 <= command < 0x10
            if (command < Commands.V4_SWAP) {
                // 0x00 <= command < 0x08
                if (command < Commands.PERMIT2_PERMIT) {
                    if (command == Commands.PERMIT2_TRANSFER_FROM) {
                        // equivalent: abi.decode(inputs, (address, address, uint160))
                        address token;
                        address recipient;
                        uint160 amount;
                        assembly {
                            token := calldataload(inputs.offset)
                            recipient := calldataload(add(inputs.offset, 0x20))
                            amount := calldataload(add(inputs.offset, 0x40))
                        }
                        permit2TransferFrom(token, msgSender(), map(recipient), amount);
                    } else if (command == Commands.PERMIT2_PERMIT_BATCH) {
                        IAllowanceTransfer.PermitBatch calldata permitBatch;
                        assembly {
                            // this is a variable length struct, so calldataload(inputs.offset) contains the
                            // offset from inputs.offset at which the struct begins
                            permitBatch := add(inputs.offset, calldataload(inputs.offset))
                        }
                        bytes calldata data = inputs.toBytes(1);
                        (success, output) = address(PERMIT2).call(
                            abi.encodeWithSignature(
                                "permit(address,((address,uint160,uint48,uint48)[],address,uint256),bytes)",
                                msgSender(),
                                permitBatch,
                                data
                            )
                        );
                    } else if (command == Commands.SWEEP) {
                        // equivalent:  abi.decode(inputs, (address, address, uint256))
                        address token;
                        address recipient;
                        uint160 amountMin;
                        assembly {
                            token := calldataload(inputs.offset)
                            recipient := calldataload(add(inputs.offset, 0x20))
                            amountMin := calldataload(add(inputs.offset, 0x40))
                        }
                        Payments.sweep(token, map(recipient), amountMin);
                    } else if (command == Commands.TRANSFER) {
                        // equivalent:  abi.decode(inputs, (address, address, uint256))
                        address token;
                        address recipient;
                        uint256 value;
                        assembly {
                            token := calldataload(inputs.offset)
                            recipient := calldataload(add(inputs.offset, 0x20))
                            value := calldataload(add(inputs.offset, 0x40))
                        }
                        Payments.pay(token, map(recipient), value);
                    } else if (command == Commands.PAY_PORTION) {
                        // equivalent:  abi.decode(inputs, (address, address, uint256))
                        address token;
                        address recipient;
                        uint256 bips;
                        assembly {
                            token := calldataload(inputs.offset)
                            recipient := calldataload(add(inputs.offset, 0x20))
                            bips := calldataload(add(inputs.offset, 0x40))
                        }
                        Payments.payPortion(token, map(recipient), bips);
                    } else {
                        // placeholder area for command 0x07
                        InvalidCommandType.selector.revertWith(command);
                    }
                } else {
                    // 0x08 <= command < 0x10
                    if (command == Commands.PERMIT2_PERMIT) {
                        // equivalent: abi.decode(inputs, (IAllowanceTransfer.PermitSingle, bytes))
                        IAllowanceTransfer.PermitSingle calldata permitSingle;
                        assembly {
                            permitSingle := inputs.offset
                        }
                        bytes calldata data = inputs.toBytes(6); // PermitSingle takes first 6 slots (0..5)
                        (success, output) = address(PERMIT2).call(
                            abi.encodeWithSignature(
                                "permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)",
                                msgSender(),
                                permitSingle,
                                data
                            )
                        );
                    } else if (command == Commands.WRAP_ETH) {
                        // equivalent: abi.decode(inputs, (address, uint256))
                        address recipient;
                        uint256 amount;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            amount := calldataload(add(inputs.offset, 0x20))
                        }
                        Payments.wrapETH(map(recipient), amount);
                    } else if (command == Commands.UNWRAP_WETH) {
                        // equivalent: abi.decode(inputs, (address, uint256))
                        address recipient;
                        uint256 amountMin;
                        assembly {
                            recipient := calldataload(inputs.offset)
                            amountMin := calldataload(add(inputs.offset, 0x20))
                        }
                        Payments.unwrapWETH9(map(recipient), amountMin);
                    } else if (command == Commands.PERMIT2_TRANSFER_FROM_BATCH) {
                        IAllowanceTransfer.AllowanceTransferDetails[] calldata batchDetails;
                        (uint256 length, uint256 offset) = inputs.toLengthOffset(0);
                        assembly {
                            batchDetails.length := length
                            batchDetails.offset := offset
                        }
                        permit2TransferFrom(batchDetails, msgSender());
                    } else if (command == Commands.BALANCE_CHECK_ERC20) {
                        // equivalent: abi.decode(inputs, (address, address, uint256))
                        address owner;
                        address token;
                        uint256 minBalance;
                        assembly {
                            owner := calldataload(inputs.offset)
                            token := calldataload(add(inputs.offset, 0x20))
                            minBalance := calldataload(add(inputs.offset, 0x40))
                        }
                        success = (ERC20(token).balanceOf(owner) >= minBalance);
                        if (!success) output = abi.encodePacked(BalanceTooLow.selector);
                    } else {
                        // placeholder area for command 0x0f
                        InvalidCommandType.selector.revertWith(command);
                    }
                }
            } else {
                // 0x10 <= command < 0x21
                if (command == Commands.V4_SWAP) {
                    // pass the calldata provided to V4SwapRouter._executeActions (defined in BaseActionsRouter)
                    _executeActions(inputs);
                    // This contract MUST be approved to spend the token since its going to be doing the call on the position manager
                } else {
                    // placeholder area for commands 0x15-0x20
                    InvalidCommandType.selector.revertWith(command);
                }
            }
        } else {
            // 0x21 <= command < 0x32
            if (command < Commands.TP_SPLIT_INITIAL_LIQUIDITY) {
                // 0x21 <= command < 0x2a
                if (command < Commands.VAULT_CONNECTOR_DEPOSIT) {
                    if (command == Commands.EXECUTE_SUB_PLAN) {
                        (bytes calldata _commands, bytes[] calldata _inputs) = inputs.decodeCommandsAndInputs();
                        (success, output) =
                            (address(this)).call(abi.encodeCall(Dispatcher.execute, (_commands, _inputs)));
                    } else if (command == Commands.PT_SUPPLY) {
                        address principalToken;
                        uint256 shares;
                        address receiver;
                        assembly {
                            principalToken := calldataload(inputs.offset)
                            shares := calldataload(add(inputs.offset, 0x20))
                            receiver := calldataload(add(inputs.offset, 0x40))
                        }
                        _principalTokenSupply(PrincipalToken(principalToken), shares, map(receiver));
                    } else if (command == Commands.PT_REDEEM) {
                        address principalToken;
                        uint256 principals;
                        address receiver;
                        assembly {
                            principalToken := calldataload(inputs.offset)
                            principals := calldataload(add(inputs.offset, 0x20))
                            receiver := calldataload(add(inputs.offset, 0x40))
                        }
                        _principalTokenRedeem(PrincipalToken(principalToken), principals, map(receiver));
                    } else if (command == Commands.PT_COMBINE) {
                        address principalToken;
                        uint256 principals;
                        address receiver;
                        assembly {
                            principalToken := calldataload(inputs.offset)
                            principals := calldataload(add(inputs.offset, 0x20))
                            receiver := calldataload(add(inputs.offset, 0x40))
                        }
                        _principalTokenCombine(PrincipalToken(principalToken), principals, map(receiver));
                    } else if (command == Commands.PT_COLLECT) {
                        address principalToken;
                        address receiver;
                        PermitCollectInput calldata permit;
                        assembly {
                            principalToken := calldataload(inputs.offset)
                            receiver := calldataload(add(inputs.offset, 0x20))
                            permit := add(inputs.offset, 0x40)
                        }
                        _principalTokenCollect(PrincipalToken(principalToken), map(receiver), permit);
                    } else {
                        // placeholder area for commands 0x26-0x29
                        InvalidCommandType.selector.revertWith(command);
                    }
                } else {
                    // 0x2a <= command < 0x32
                    if (command == Commands.VAULT_CONNECTOR_DEPOSIT) {
                        address target;
                        address asset;
                        address token;
                        uint256 amountIn;
                        address receiver;
                        assembly {
                            target := calldataload(inputs.offset)
                            asset := calldataload(add(inputs.offset, 0x20))
                            token := calldataload(add(inputs.offset, 0x40))
                            amountIn := calldataload(add(inputs.offset, 0x60))
                            receiver := calldataload(add(inputs.offset, 0x80))
                        }
                        _connectorDeposit(target, asset, Token.wrap(token), amountIn, map(receiver));
                    } else if (command == Commands.VAULT_CONNECTOR_REDEEM) {
                        address target;
                        address asset;
                        address tokenOut;
                        uint256 shares;
                        address receiver;
                        assembly {
                            target := calldataload(inputs.offset)
                            asset := calldataload(add(inputs.offset, 0x20))
                            tokenOut := calldataload(add(inputs.offset, 0x40))
                            shares := calldataload(add(inputs.offset, 0x60))
                            receiver := calldataload(add(inputs.offset, 0x80))
                        }
                        _connectorRedeem(target, asset, Token.wrap(tokenOut), shares, map(receiver));
                    } else if (command == Commands.AGGREGATOR_SWAP) {
                        // equivalent: abi.decode(inputs, (address, address, uint256, address, RouterPayload))
                        Token tokenIn;
                        Token tokenOut;
                        uint256 amountIn;
                        address recipient;
                        RouterPayload calldata data;
                        assembly {
                            tokenIn := calldataload(inputs.offset)
                            tokenOut := calldataload(add(inputs.offset, 0x20))
                            amountIn := calldataload(add(inputs.offset, 0x40))
                            recipient := calldataload(add(inputs.offset, 0x60))
                            // RouterPayload is at offset 0x80, but since it's a struct with dynamic data,
                            // we need to read its offset first, then add that to inputs.offset
                            let payloadOffset := calldataload(add(inputs.offset, 0x80))
                            data := add(inputs.offset, payloadOffset)
                        }
                        _swapViaAggregator(tokenIn, tokenOut, amountIn, map(recipient), data);
                    } else if (command == Commands.CREATE_WRAPPER) {
                        address _msgSender = msgSender();
                        address implementation;
                        bytes32 salt;
                        assembly {
                            implementation := calldataload(inputs.offset)
                            salt := calldataload(add(inputs.offset, 0x20))
                            mstore(0x00, _msgSender)
                            mstore(0x20, salt)
                            salt := keccak256(0x00, 0x40) // salt = keccak256(abi.encode(_msgSender, salt))
                        }
                        bytes calldata args = inputs.toBytes(2);
                        _i_wrapperFactory.createWrapper(implementation, args, salt);
                    } else {
                        // placeholder area for commands 0x2e-0x31
                        InvalidCommandType.selector.revertWith(command);
                    }
                }
            } else {
                // 0x32 <= command < 0x3f
                if (command == Commands.TP_SPLIT_INITIAL_LIQUIDITY) {
                    PoolKey calldata key;
                    uint256 amount0;
                    address receiver;
                    uint256 desiredImpliedRate;
                    assembly {
                        key := inputs.offset
                        amount0 := calldataload(add(inputs.offset, 0xa0))
                        receiver := calldataload(add(inputs.offset, 0xc0))
                        desiredImpliedRate := calldataload(add(inputs.offset, 0xe0))
                    }
                    _splitInitialLiquidity(key, amount0, map(receiver), desiredImpliedRate);
                } else if (command == Commands.TP_SPLIT_UNDERLYING_TOKEN_LIQUIDITY_KEEP_YT) {
                    PoolKey calldata key;
                    uint256 amount0;
                    address receiver;
                    assembly {
                        key := inputs.offset
                        amount0 := calldataload(add(inputs.offset, 0xa0))
                        receiver := calldataload(add(inputs.offset, 0xc0))
                    }
                    _splitUnderlyingTokenLiquidityKeepYt(key, amount0, map(receiver));
                } else if (command == Commands.TP_SPLIT_UNDERLYING_TOKEN_LIQUIDITY_NO_YT) {
                    PoolKey calldata key;
                    uint256 amount0;
                    ApproximationParams calldata approx;
                    assembly {
                        key := inputs.offset
                        amount0 := calldataload(add(inputs.offset, 0xa0))
                        approx := add(inputs.offset, 0xc0)
                    }
                    _splitUnderlyingTokenLiquidityNoYt(key, amount0, approx);
                } else if (command == Commands.TP_CREATE_POOL) {
                    Factory.Suite memory suite = abi.decode(inputs, (Factory.Suite));
                    Factory.ModuleParam[] calldata modules;
                    uint256 expiry;
                    address curator;
                    bytes32 salt;
                    assembly {
                        //  Layout of the calldata
                        //   ┌──────────────────────────────────────┐
                        //   │ Suite                                │ The pointer to the content of the Suite struct
                        //   ├──────────────────────────────────────┤
                        //   │ Pointer to ModuleParam[]             │ The pointer to where the array data starts
                        //   ├──────────────────────────────────────┤
                        //   │ expiry                               │
                        //   ├──────────────────────────────────────┤
                        //   │ curator                              │
                        //   ├──────────────────────────────────────┤
                        //   │ salt                                 │
                        //   └──────────────────────────────────────┘
                        //                       ↓
                        //   ARRAY DATA:
                        //   ┌──────────────────────────────────────┐
                        //   │ Suite data                           │
                        //   │ ...                                  │
                        //   │                                      │
                        //   ├──────────────────────────────────────┤
                        //   │ Length of ModuleParam[] = N          │ ← lengthPtr
                        //   ├──────────────────────────────────────┤
                        //   │ Offset[0]                            │ ← lengthPtr + 0x20
                        //   │ Offset[1]                            │
                        //   │ ...                                  │
                        //   │ Offset[N-1]                          │
                        //   ├──────────────────────────────────────┤
                        //   │ Module[0] complete struct data       │
                        //   │ Module[1] complete struct data       │
                        //   │ ...                                  │
                        //   │ Module[N-1] complete struct data     │
                        //   └──────────────────────────────────────┘
                        let arrayOffset := calldataload(add(inputs.offset, 0x20))
                        let lengthPtr := add(inputs.offset, arrayOffset) // The place where the length of the ModuleParam[] is stored
                        modules.length := calldataload(lengthPtr)
                        modules.offset := add(lengthPtr, 0x20) // The pointer to the first content of the ModuleParam[]

                        expiry := calldataload(add(inputs.offset, 0x40))
                        curator := calldataload(add(inputs.offset, 0x60))
                        salt := calldataload(add(inputs.offset, 0x80))
                    }

                    _createTokiPool(suite, modules, expiry, curator, salt);
                } else if (command == Commands.TP_ADD_LIQUIDITY) {
                    PoolKey calldata key;
                    uint256 amount0;
                    uint256 amount1;
                    address receiver;
                    uint256 liquidityMinimum;
                    assembly {
                        key := inputs.offset
                        amount0 := calldataload(add(inputs.offset, 0xa0))
                        amount1 := calldataload(add(inputs.offset, 0xc0))
                        liquidityMinimum := calldataload(add(inputs.offset, 0xe0))
                        receiver := calldataload(add(inputs.offset, 0x100))
                    }
                    _addLiquidity(key, amount0, amount1, liquidityMinimum, map(receiver));
                } else if (command == Commands.TP_REMOVE_LIQUIDITY) {
                    PoolKey calldata key;
                    uint256 liquidity;
                    uint256 amount0Minimum;
                    uint256 amount1Minimum;
                    address receiver;
                    assembly {
                        key := inputs.offset
                        liquidity := calldataload(add(inputs.offset, 0xa0))
                        amount0Minimum := calldataload(add(inputs.offset, 0xc0))
                        amount1Minimum := calldataload(add(inputs.offset, 0xe0))
                        receiver := calldataload(add(inputs.offset, 0x100))
                    }
                    _removeLiquidity(key, liquidity, amount0Minimum, amount1Minimum, map(receiver));
                } else if (command == Commands.YT_SWAP_UNDERLYING_FOR_YT) {
                    PoolKey calldata key;
                    uint256 amountIn;
                    uint256 amountOutMinimum;
                    address recipient;
                    address refundReceiver;
                    ApproximationParams calldata approx;
                    assembly {
                        key := inputs.offset
                        amountIn := calldataload(add(inputs.offset, 0xa0))
                        amountOutMinimum := calldataload(add(inputs.offset, 0xc0))
                        recipient := calldataload(add(inputs.offset, 0xe0))
                        refundReceiver := calldataload(add(inputs.offset, 0x100))
                        approx := add(inputs.offset, 0x120)
                    }
                    _swapUnderlyingForYt(key, amountIn, amountOutMinimum, map(recipient), map(refundReceiver), approx);
                } else if (command == Commands.YT_SWAP_YT_FOR_UNDERLYING) {
                    PoolKey calldata key;
                    uint256 amountIn;
                    uint256 amountOutMinimum;
                    address recipient;
                    assembly {
                        key := inputs.offset
                        amountIn := calldataload(add(inputs.offset, 0xa0))
                        amountOutMinimum := calldataload(add(inputs.offset, 0xc0))
                        recipient := calldataload(add(inputs.offset, 0xe0))
                    }
                    _swapYtForUnderlying(key, amountIn, amountOutMinimum, map(recipient));
                } else {
                    // placeholder area for commands 0x3a-0x3f
                    InvalidCommandType.selector.revertWith(command);
                }
            }
        }
    }

    /// @notice Calculates the recipient address for a command
    /// @param recipient The recipient or recipient-flag for the command
    /// @return output The resultant recipient for the command
    function map(address recipient) internal view returns (address) {
        if (recipient == ActionConstants.MSG_SENDER) {
            return msgSender();
        } else if (recipient == ActionConstants.ADDRESS_THIS) {
            return address(this);
        } else {
            return recipient;
        }
    }
}
