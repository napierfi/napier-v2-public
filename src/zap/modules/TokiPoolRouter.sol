// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Router, Actions, ActionConstants} from "@uniswap/v4-periphery/src/V4Router.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {PoolFeeModule} from "../../modules/PoolFeeModule.sol";
import {PrincipalToken} from "../../tokens/PrincipalToken.sol";
import {Factory} from "../../Factory.sol";
import {TokiHook, ITokiHook, ImmutableParamsLib} from "../../hooks/TokiHook.sol";
import {StateLibrary} from "../../interfaces/ITokiHook.sol";
import {TokiPoolToken} from "../../tokens/TokiPoolToken.sol";

import {TokiSwap} from "../../utils/TokiSwap.sol";
import {LibExpiry} from "../../utils/LibExpiry.sol";
import {CustomRevert} from "../../utils/CustomRevert.sol";
import {TransientState} from "./TransientState.sol";
import {FunctionTypeCasts} from "../../utils/FunctionTypeCasts.sol";
import {ContractValidation} from "../../utils/ContractValidation.sol";

import "../../Types.sol";
import "../../Errors.sol";
import {IHook} from "../../interfaces/IHook.sol";
import {LibApproval} from "../../utils/LibApproval.sol";
import {NapierV2Immutables} from "./NapierV2Immutables.sol";
import {V4Permit2Payments} from "./V4Permit2Payments.sol";

/// @notice Router module for atomic YT swap operations using V4 infrastructure
/// @dev Must implement IUnlockCallback, full access to V4 Actions through unlockCallback()
abstract contract TokiPoolRouter is NapierV2Immutables, ImmutableState, V4Permit2Payments, LibApproval, IHook {
    using SafeCastLib for *;
    using CustomRevert for *;
    using FunctionTypeCasts for *;

    bytes constant COMMAND_V4_SWAP_EXACT_OUT = abi.encodePacked(
        bytes1(uint8(Actions.SWAP_EXACT_OUT_SINGLE)), bytes1(uint8(Actions.SETTLE)), bytes1(uint8(Actions.TAKE))
    );

    bytes constant COMMAND_V4_SWAP_EXACT_IN = abi.encodePacked(
        bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)), bytes1(uint8(Actions.SETTLE)), bytes1(uint8(Actions.TAKE))
    );

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      POOL CREATION                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Create a new TokiPool
    /// @dev Store the pool key in transition storage for later use. If there is an existing key, it will be overwritten.
    function _createTokiPool(
        Factory.Suite memory suite,
        Factory.ModuleParam[] calldata modules,
        uint256 expiry,
        address curator,
        bytes32 salt
    ) internal {
        // Salt for deterministic deployment
        // Hash sender into salt to prevent griefing via frontrunning
        bytes32 sender = bytes32(uint256(uint160(msgSender())));

        bytes memory poolArgs = suite.poolArgs; // poolArgs is abi.encode(ITokiHook.TokiPoolDeploymentParams)
        // Assembly to access the salt without decoding the whole struct
        assembly {
            let slot := add(poolArgs, 0x40)
            let poolSalt := mload(slot) // Note: assume the first field of the struct is the salt
            // EfficientHashLib.hash(sender, salt)
            mstore(0x00, sender)
            mstore(0x20, poolSalt)
            poolSalt := keccak256(0x00, 0x40)

            // Write the new salt back to the memory
            mstore(slot, poolSalt)

            // PrincipalToken salt
            // EfficientHashLib.hash(sender, salt)
            mstore(0x20, salt)
            salt := keccak256(0x00, 0x40)
        }

        (,, address pool) = _i_factory.deployDeterministic(suite, modules, expiry, curator, salt);

        // If the call reverts, the pool is not uniswap v4 custom hook pool.
        TransientState.setPoolKey(TokiPoolToken(pool).i_poolKey());
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          LIQUIDITY                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Reference: https://github.com/pendle-finance/pendle-core-v2-public/blob/a9f5b99dbda7e6a8ec448cdd49c497a7499a0c3c/contracts/offchain-helpers/deploy/PendlePoolDeployHelperV2.sol#L157
    /// @notice Split part of initial liquidity into PTs and spending them issuing PTs and YTs
    /// @dev This function means to be used with `TP_ADD_LIQUIDITY`
    /// @dev Integrators can prepend a `SWEEP` command at the top of the command sequence
    ///      External actors may donate underlying tokens to the router ahead of the user's transaction.
    ///      Those donations reduce the pool's proportion of PTs available to `TP_ADD_LIQUIDITY`, producing an lnImpliedRate below the requested `desiredImpliedRate`.
    /// @param receiver YT receiver address. PTs are issued to router contract
    /// @param desiredImpliedRate The desired implied rate in wad (Note e.g. 0.185e18 for 18.5%)
    function _splitInitialLiquidity(PoolKey memory key, uint256 amount0, address receiver, uint256 desiredImpliedRate)
        internal
    {
        // If key is not provided, load from transition storage
        if (_isZeroKey(key)) {
            key = TransientState.getPoolKey();
        }

        // Check if pool exists
        ContractValidation.checkTokiPoolExists(key.toId(), _i_tokiPoolDeployer);

        PrincipalToken pt = PrincipalToken(Currency.unwrap(key.currency1));

        ITokiHook.ImmutableParams memory immutables =
            ImmutableParamsLib.decodeFor.asImmutableParams()(TokiHook(address(key.hooks)), key.toId());

        // Compute initial proportion
        LibExpiry.checkNotExpired(immutables.expiry);
        uint256 initialProportion = TokiSwap.computeInitialProportion(
            immutables.expiry, immutables.scalarRoot, immutables.initialAnchor, desiredImpliedRate
        );

        // Transfer underlying token to the contract
        amount0 = payIfNeeded(Currency.unwrap(key.currency0), amount0);

        approveIfNeeded(Currency.unwrap(key.currency0), address(pt));

        // Issue PTs and YTs with part of underlying token liquidity
        // Remaining amount of underlying token `amount0 - amount0ToTokenize` is going to be left in the contract, then deposited to the pool later
        uint256 amount0ToTokenize = (amount0 * initialProportion) / 1e18;
        uint256 principals = pt.supply(amount0ToTokenize, address(this));

        // Send YTs to receiver
        SafeTransferLib.safeTransfer(_getYt(key.currency1), receiver, principals);
    }

    /// @dev Reference: https://github.com/pendle-finance/pendle-core-v2-public/blob/19317a9588b5fd68cc04e8f4b0f5613dac172e30/contracts/router/ActionAddRemoveLiqV3.sol#L308
    /// @notice Split part of underlying token liquidity into PTs and spending them issuing PTs and YTs
    /// @notice This function doesn't support initial liquidity. Use `_splitInitialLiquidity` instead.
    /// @dev This function means to be used with `TP_ADD_LIQUIDITY` and `amount0 == ActionConstants.CONTRACT_BALANCE` to deposit liquidity with a single token keeping pool balances ratio unchanged
    function _splitUnderlyingTokenLiquidityKeepYt(PoolKey calldata key, uint256 amount0, address receiver) internal {
        // Check if pool exists
        ContractValidation.checkTokiPoolExists(key.toId(), _i_tokiPoolDeployer);

        amount0 = payIfNeeded(Currency.unwrap(key.currency0), amount0);

        PrincipalToken pt = PrincipalToken(Currency.unwrap(key.currency1));

        Uint128x2 balances = TokiHook(address(key.hooks)).getTotalBalances(key.toId());
        // Calculate proportion to maintain current pool ratio
        // Both denominator terms are in asset decimals (PT decimals = asset decimals):
        // - balances.value1(): Current PT balance in PT units
        // - convertToAssets(...): PT-equivalent value of underlying balance in asset units
        uint256 cscale = pt.i_resolver().scale();
        uint256 maxscale = pt.getSnapshot().maxscale;
        if (cscale > maxscale) maxscale = cscale;

        // This ratio treats balances as fee-less; issuance fees charged by PrincipalToken.supply()
        // will reduce the actual principals minted when we tokenize, leading to a minor imbalance if fees are high.
        uint256 amount0ToTokenize =
            (amount0 * balances.value1()) / (balances.value1() + TokiSwap.convertToAssets(balances.value0(), maxscale));

        approveIfNeeded(Currency.unwrap(key.currency0), address(pt));

        // Issue PTs and YTs with part of underlying token liquidity
        // Remaining amount of underlying token `amount0 - amount0ToTokenize` is going to be left in the contract, then deposited to the pool later
        uint256 principals = pt.supply(amount0ToTokenize, address(this));

        // Send YTs to receiver
        SafeTransferLib.safeTransfer(_getYt(key.currency1), receiver, principals);
    }

    /// @dev Reference: https://github.com/pendle-finance/pendle-core-v2-public/blob/19317a9588b5fd68cc04e8f4b0f5613dac172e30/contracts/router/ActionAddRemoveLiqV3.sol#L206
    /// @notice Split part of underlying token liquidity into PTs
    /// @notice This function doesn't support initial liquidity. Use `_splitInitialLiquidity` instead.
    /// @dev This function means to be used with `TP_ADD_LIQUIDITY` and `amount0 == ActionConstants.CONTRACT_BALANCE` to deposit liquidity with a single token but without issuing YTs
    function _splitUnderlyingTokenLiquidityNoYt(
        PoolKey calldata key,
        uint256 amount0,
        ApproximationParams calldata approx
    ) internal {
        // Check if pool exists
        ContractValidation.checkTokiPoolExists(key.toId(), _i_tokiPoolDeployer);

        amount0 = payIfNeeded(Currency.unwrap(key.currency0), amount0);

        // Find the optimal amount of PT to be sold to add liquidity with a single token but without issuing YTs
        (
            ,
            int256 bestPt, // Positive
            ,
        ) = _i_tokiSwapBinSearch.computeSwapExactPrincipalToAddLiquidity(key, amount0, approx);

        // Prepare inputs for V4 swap
        // SWAP_EXACT_OUT_SINGLE: Swap underlying -> PT
        // SETTLE: Pay underlying debt to PM (delta0)
        // TAKE: Claim PT credit from PM (principals)

        bytes[] memory inputs =
            _encodeV4SwapCommands(key, key.currency0, key.currency1, true, uint256(bestPt), type(uint128).max);

        // Execute V4 commands within callback
        _unlock(abi.encodeCall(poolManager.unlock, (abi.encode(COMMAND_V4_SWAP_EXACT_OUT, inputs))));
    }

    /// @dev If key is not provided, load from transition storage
    function _addLiquidity(
        PoolKey memory key,
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 liquidityMinimum,
        address receiver
    ) internal {
        if (_isZeroKey(key)) {
            key = TransientState.getPoolKey();
        }

        ContractValidation.checkTokiPoolExists(key.toId(), _i_tokiPoolDeployer);

        address sender = msgSender();

        amount0Max = payIfNeeded(Currency.unwrap(key.currency0), amount0Max);
        amount1Max = payIfNeeded(Currency.unwrap(key.currency1), amount1Max);

        TokiHook hook = TokiHook(address(key.hooks));

        approveIfNeeded(Currency.unwrap(key.currency0), address(hook));
        approveIfNeeded(Currency.unwrap(key.currency1), address(hook));

        (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent) = hook.addLiquidity({
            key: key,
            amount0Desired: amount0Max,
            amount1Desired: amount1Max,
            receiver: receiver,
            refundReceiver: sender
        });

        if (liquidity < liquidityMinimum) {
            Errors.Zap_InsufficientLiquidity.selector.revertWith();
        }

        if (amount0Spent < amount0Max) {
            unchecked {
                SafeTransferLib.safeTransfer(Currency.unwrap(key.currency0), sender, amount0Max - amount0Spent);
            }
        }

        if (amount1Spent < amount1Max) {
            unchecked {
                SafeTransferLib.safeTransfer(Currency.unwrap(key.currency1), sender, amount1Max - amount1Spent);
            }
        }
    }

    function _removeLiquidity(
        PoolKey calldata key,
        uint256 liquidity,
        uint256 amount0Minimum,
        uint256 amount1Minimum,
        address receiver
    ) internal {
        ContractValidation.checkTokiPoolExists(key.toId(), _i_tokiPoolDeployer);

        TokiHook hook = TokiHook(address(key.hooks));

        address liquidityToken = ImmutableParamsLib.getLiquidityToken(hook, key.toId());

        liquidity = payIfNeeded(liquidityToken, liquidity);

        (uint256 amount0, uint256 amount1) = hook.removeLiquidity({key: key, liquidity: liquidity, receiver: receiver});

        if (amount0 < amount0Minimum) {
            Errors.Zap_InsufficientUnderlyingOutput.selector.revertWith();
        }

        if (amount1 < amount1Minimum) {
            Errors.Zap_InsufficientPrincipalTokenOutput.selector.revertWith();
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            SWAP                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Swap underlying tokens for YT
    /// @dev Reference: https://github.com/pendle-finance/pendle-core-v2-public/blob/19317a9588b5fd68cc04e8f4b0f5613dac172e30/contracts/router/ActionAddRemoveLiqV3.sol#L100
    function _swapUnderlyingForYt(
        PoolKey calldata key,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient,
        address refundReceiver,
        ApproximationParams memory approx
    ) internal {
        // Check if pool is registered
        ContractValidation.checkTokiPoolExists(key.toId(), _i_tokiPoolDeployer);

        bool useContractBalance = amountIn == ActionConstants.CONTRACT_BALANCE;
        if (useContractBalance) {
            amountIn = SafeTransferLib.balanceOf(Currency.unwrap(key.currency0), address(this));
        }

        // Binary search to find optimal PT amount to be flash swapped beforehand
        (
            int256 bestUnderlying, // Positive
            int256 _bestPt, // Negative because we're selling PT
            ,
            ,
            uint256 previewDebt
        ) = _i_tokiSwapBinSearch.computeUnderlyingForYtSwap(key, amountIn, approx);

        uint256 underlyingAvailable = uint256(bestUnderlying) + amountIn;

        if (previewDebt > underlyingAvailable) {
            // Something went wrong in the binary search or rounding error
            Errors.Zap_DebtExceedsUnderlyingReceived.selector.revertWith();
        }

        uint256 excess;
        unchecked {
            excess = underlyingAvailable - previewDebt; // The amount of underlying that is not going to be used
        }
        uint256 amountToTransfer = amountIn - excess; // Usually underflow shouldn't happen, or it means YT is free.

        uint256 bestPt = uint256(-_bestPt);
        if (bestPt < amountOutMinimum) {
            Errors.Zap_InsufficientYieldTokenOutput.selector.revertWith();
        }

        // If the router spends contract balance, the excess is going to be refunded to refundReceiver
        // Refund doesn't happen if the router is spending user's balance
        if (useContractBalance && refundReceiver != address(this) && excess > 0) {
            // Skip transfer to self
            SafeTransferLib.safeTransfer(Currency.unwrap(key.currency0), refundReceiver, excess);
        }

        TransientState.setCallbacker(Currency.unwrap(key.currency1));

        // Flash mint PT+YT via PrincipalToken.issue()
        // This triggers onSupply callback within same unlock cycle
        // Equivalent to: abi.encode(key, amountToTransfer, bestUnderlying, useContractBalance);
        bytes memory payload = new bytes(0x100);
        assembly {
            calldatacopy(add(payload, 0x20), key, 0xa0)
            mstore(add(payload, 0xc0), amountToTransfer)
            mstore(add(payload, 0xe0), bestUnderlying)
            mstore(add(payload, 0x100), useContractBalance)
        }
        PrincipalToken(Currency.unwrap(key.currency1)).issue(
            bestPt,
            address(this), // receiver of PT+YT
            payload
        );

        // Send YT to recipient
        // Refund excess underlying to refundReceiver
        address yt = address(PrincipalToken(Currency.unwrap(key.currency1)).i_yt());
        SafeTransferLib.safeTransfer(yt, recipient, bestPt);
    }

    /// @notice Swap YT for underlying tokens
    /// @dev Reference: https://github.com/pendle-finance/pendle-core-v2-public/blob/19317a9588b5fd68cc04e8f4b0f5613dac172e30/contracts/router/base/ActionBase.sol#L262
    /// @dev NOTE: Hooklets are PROHIBITED from modifying pool balances. If a buggy/malicious
    ///      hooklet violates this rule, the actual underlying cost for the PT swap may differ
    ///      from `underlyingDebt` estimate. Any surplus remains in router for user to defensively
    ///      SWEEP. With compliant hooklets, calculations are exact and no surplus occurs.
    function _swapYtForUnderlying(PoolKey calldata key, uint256 amountIn, uint256 amountOutMinimum, address recipient)
        internal
    {
        // Check if pool is registered
        ContractValidation.checkTokiPoolExists(key.toId(), _i_tokiPoolDeployer);

        address YT = _getYt(key.currency1);

        amountIn = payIfNeeded(YT, amountIn);

        // Calculate the amount of underlying needed to buy the exact amount of PTs on the market
        (int256 _underlyingDebt,,,) = _i_tokiSwapBinSearch.computeYtForUnderlyingSwap(key, amountIn);
        uint256 underlyingDebt = uint256(-_underlyingDebt);

        // Flash redeem PTs and YTs and invoke onUnite callback
        TransientState.setCallbacker(Currency.unwrap(key.currency1));

        uint256 underlyingWithdrawn = PrincipalToken(Currency.unwrap(key.currency1)).combine(
            amountIn, address(this), abi.encode(key, underlyingDebt)
        );

        uint256 amountOut = underlyingWithdrawn - underlyingDebt;

        if (amountOut < amountOutMinimum) {
            Errors.Zap_InsufficientUnderlyingOutput.selector.revertWith();
        }

        SafeTransferLib.safeTransfer(Currency.unwrap(key.currency0), recipient, amountOut);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CALLBACKS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Callback from PrincipalToken.issue()
    /// @dev Executes V4 swap within the callback to settle flash mint
    /// @dev NOTE: Hooklets are PROHIBITED from modifying pool balances. If a buggy/malicious
    ///      hooklet violates this rule by modifying balances in beforeSwap(), the actual swap
    ///      output may differ from `bestUnderlying` estimate. Any surplus remains in router for
    ///      user to defensively SWEEP. With compliant hooklets, no surplus occurs.
    function onSupply(uint256, /* underlyingDebt */ uint256 principals, bytes calldata data) external override {
        // Verify callback authorization
        _verifyCallback();

        PoolKey calldata key;
        uint256 amountToTransfer;
        uint256 bestUnderlying;
        bool useContractBalance;
        assembly {
            key := data.offset
            amountToTransfer := calldataload(add(data.offset, 0xa0))
            bestUnderlying := calldataload(add(data.offset, 0xc0))
            useContractBalance := calldataload(add(data.offset, 0xe0))
        }

        address payer = useContractBalance ? address(this) : msgSender();

        payOrPermit2Transfer(
            Currency.unwrap(key.currency0), payer, Currency.unwrap(key.currency1), amountToTransfer.toUint160()
        );

        // Note revert with non-zero delta if something went wrong in the following actions

        // Prepare V4 inputs for swap PT for underlying
        // We need to swap enough PT to cover the underlying debt

        // SWAP_EXACT_IN_SINGLE: Swap PT -> underlying
        // SETTLE_ALL: Pay PT debt to PM
        // TAKE_ALL: Claim underlying credit from PM
        bytes[] memory inputs =
            _encodeV4SwapCommands(key, key.currency1, key.currency0, false, principals, bestUnderlying);

        // Execute V4 commands within callback
        _unlock(abi.encodeCall(poolManager.unlock, (abi.encode(COMMAND_V4_SWAP_EXACT_IN, inputs))));

        // Repay rest of the underlying debt to PrincipalToken
        SafeTransferLib.safeTransfer(Currency.unwrap(key.currency0), msg.sender, bestUnderlying);
    }

    /// @notice Callback from PrincipalToken.combine()
    /// @dev Executes V4 swap within the callback to acquire needed PT
    function onUnite(uint256 underlyingWithdrawn, uint256 principals, bytes calldata data) external override {
        // Verify callback authorization
        _verifyCallback();

        PoolKey calldata key;
        uint256 underlyingDebt;
        assembly {
            key := data.offset
            underlyingDebt := calldataload(add(data.offset, 0xa0))
        }

        if (underlyingWithdrawn < underlyingDebt) {
            Errors.Zap_DebtExceedsUnderlyingReceived.selector.revertWith();
        }

        // Note revert with non-zero delta if something went wrong in the following actions

        // Prepare V4 inputs
        // SWAP_EXACT_OUT_SINGLE: Swap underlying -> PT
        // SETTLE: Pay underlying debt to PM (delta0)
        // TAKE: Claim PT credit from PM (principals)
        bytes[] memory inputs =
            _encodeV4SwapCommands(key, key.currency0, key.currency1, true, principals, underlyingDebt);

        // Execute V4 commands within callback
        _unlock(abi.encodeCall(poolManager.unlock, (abi.encode(COMMAND_V4_SWAP_EXACT_OUT, inputs))));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         HELPERS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _verifyCallback() internal {
        address callbacker = TransientState.getAndClearCallbacker();
        if (callbacker != msg.sender) Errors.Zap_BadCallback.selector.revertWith();
    }

    /// @dev It's meant to be used for checking if the transient PoolKey is set or not
    function _isZeroKey(PoolKey memory key) internal pure returns (bool) {
        return key.currency1 == Currency.wrap(address(0));
    }

    /// @dev Encode V4 swap commands for exact-in/out
    function _encodeV4SwapCommands(
        PoolKey calldata key,
        Currency tokenIn,
        Currency tokenOut,
        bool zeroForOne,
        uint256 amount,
        uint256 threshold
    ) internal view returns (bytes[] memory inputs) {
        inputs = new bytes[](3);

        // SWAP_EXACT_IN_SINGLE or SWAP_EXACT_OUT_SINGLE
        // Note: We use the ExactInputSingleParams for both exact-in/out for gas optimization
        // For exact-out, amountIn -> amountOut, amountOutMinimum -> amountInMaximum
        inputs[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amount.toUint128(),
                amountOutMinimum: threshold.toUint128(),
                hookData: ""
            })
        );

        // SETTLE
        inputs[1] = abi.encode(
            tokenIn,
            ActionConstants.OPEN_DELTA,
            false // payerIsUser
        );

        // TAKE
        inputs[2] = abi.encode(tokenOut, address(this), ActionConstants.OPEN_DELTA);
    }

    /// @dev Optimized call to `poolManager.unlock` with `data` as calldata. The data must be abi-encoded with the unlock function selector.
    function _unlock(bytes memory data) internal {
        address target = address(poolManager);
        assembly {
            if iszero(call(gas(), target, 0, add(data, 0x20), mload(data), 0x00, 0x00)) {
                // Bubble up the revert if the call reverts.
                let fmp := mload(0x40)
                returndatacopy(fmp, 0x00, returndatasize())
                revert(fmp, returndatasize())
            }
        }
    }

    /// @dev Optimized call to `PrincipalToken.i_yt()`
    function _getYt(Currency currency1) internal view returns (address yt) {
        // return address(PrincipalToken(Currency.unwrap(currency1)).i_yt());
        assembly {
            mstore(0x00, 0x5b593696) // `i_yt()`.
            if iszero(and(gt(returndatasize(), 0x1f), staticcall(gas(), currency1, 0x1c, 0x04, 0x00, 0x20))) {
                revert(0x0, 0x0)
            }
            yt := mload(0x00)
            // Revert if the `yt` has dirty upper bits.
            if shr(160, yt) { revert(0x0, 0x0) }
        }
    }
}
