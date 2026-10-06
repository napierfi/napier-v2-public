// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Interfaces
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {ERC4626} from "solady/src/tokens/ERC4626.sol";

import {Factory} from "../Factory.sol";
import {ITokiHook, ImmutableParamsLib} from "../interfaces/ITokiHook.sol";

// Libraries
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolKey} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import "../Types.sol";
import "../Errors.sol";
import "../Events.sol";
import "../Constants.sol" as Constants;

import {LibExpiry} from "../utils/LibExpiry.sol";
import {TokiSwap} from "../utils/TokiSwap.sol";
import {CustomRevert} from "../utils/CustomRevert.sol";
import {LibPauseGuard} from "../utils/LibPauseGuard.sol";
import {IHooklet, HookletLib} from "../utils/HookletLib.sol";
import {LiquidityAmounts} from "../utils/LiquidityAmounts.sol";
import {ContractValidation} from "../utils/ContractValidation.sol";
import {CurrencySettler} from "../utils/CurrencySettler.sol";
import {LibRehypothecation} from "../utils/LibRehypothecation.sol";
import {V4Rehypothecation} from "../utils/V4Rehypothecation.sol";
import {FunctionTypeCasts} from "../utils/FunctionTypeCasts.sol";
import {TokiHookLogic} from "./TokiHookLogic.sol";

// Inherits
import {Extsload} from "@uniswap/v4-core/src/Extsload.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {ReentrancyGuardTransient} from "solady/src/utils/ReentrancyGuardTransient.sol";
import {AccessManaged, AccessManager} from "../modules/AccessManager.sol";

/// @notice Uniswap V4 custom curve hook implementing Pendle-style yield trading for Principal Tokens
/// @dev This hook enables efficient fixed-rate trading through a custom AMM curve within Uniswap V4's framework.
///
/// @dev Trust Model & Ownership:
/// - Pool instance entirely controlled by Curator - users MUST verify Curator trustworthiness
/// - Curator responsible for all risk management decisions (vaults, hooklets, pause configurations)
/// - No governance or protocol-level control over individual pool instances
///
/// @dev Liquidity Management:
/// - Each pool deploys separate TokiPoolToken (ERC20) representing LP shares
/// - LP tokens minted/burned by hook during add/remove liquidity operations
/// - Liquidity custodied by Uniswap V4's PoolManager singleton
/// - Currency pair: Currency0 (underlying token) < Currency1 (Principal Token)
/// - Direct Uniswap V4 liquidity operations blocked
///
/// @dev Rehypothecation System:
/// - Optional feature to boost LP yields by depositing idle liquidity into ERC4626 vaults
/// - Supports separate vaults for Currency0 and Currency1
/// - Vault losses immediately socialized to all LP holders proportionally
/// - Set vault to zero address to disable rehypothecation
/// - Requires ERC4626-compliant vaults asset matching the pool currency0 and currency1
///
/// @dev Lifecycle & Pausability:
/// - Pre-maturity: Full swap and liquidity functionality enabled
/// - Post-maturity: Swaps/deposits permanently disabled
/// - Curator configures pausable functions at deployment (immutable):
///   * AddLiquidity / RemoveLiquidity operations
///   * Swap operations
///   * LP token transfers
///
/// @dev Hooklet Integration:
/// - Optional custom logic contract set at deployment (immutable)
/// - Executes on: beforeSwap, afterSwap, beforeAddLiquidity, afterAddLiquidity,
///   beforeRemoveLiquidity, afterRemoveLiquidity, beforeInitialize, afterInitialize
/// - Must implement IHooklet interface and pass contract validation
/// - Curator responsible for hooklet security and behavior
///
/// @dev Oracle & Price Tracking:
/// - Maintains TWAP oracle for logarithmic implied rates
/// - Supports up to 65,535 observations per pool
/// - Anyone can expand observation cardinality by paying gas costs
///
/// @dev AMM Curve:
/// - Dual Accounting: Raw balances (PoolManager custody) + Vault reserves (ERC4626 shares)
/// - Implements Pendle-style yield trading through a custom AMM curve
/// - Keeps track of logarithmic implied rate
/// - Logarithmic implied rate is affected by not only the pool's balance but also the external lending protocol's balance (rehypothecation)
///
/// @dev Fee Structure:
/// - All fees charged in underlying token units
/// - Split between protocol fee and curator fee (configurable ratios)
/// - Fee collection is separate from PT fee system
///
/// @dev Integration Notes:
/// - Hook blocks direct PoolManager interactions for liquidity operations
/// - Supports Vectorized's multicall for efficient batch operations
contract TokiHook is ITokiHook, AccessManaged, ReentrancyGuardTransient, BaseHook, Extsload, IUnlockCallback {
    using SafeCastLib for *;
    using FixedPointMathLib for int256;
    using CustomRevert for *;
    using FunctionTypeCasts for *;

    /// @notice Napier v2 Factory
    Factory public immutable i_factory;

    /// @notice Storage for hook
    HookStorage internal s_hookStorage;

    constructor(IPoolManager poolManager, Factory factory) BaseHook(poolManager) {
        require(ContractValidation.hasCode(address(factory)));

        i_factory = factory;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // Zero fee
            beforeAddLiquidity: true, // Disable liquidity operations
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // Custom curve hook
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // Custom curve hook
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            AMM                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Revert if caller is not a pool deployer
    /// @return poolKey The pool key `(Currency0, wCurrency1, fee=0, tickSpacing=1, hook=this)`
    function deploy(address underlying, address principalToken, TokiPoolDeploymentParams calldata params)
        external
        nonReentrant
        returns (PoolKey memory poolKey, address liquidityToken)
    {
        (poolKey, liquidityToken) = TokiHookLogic.deploy(
            TokiHookLogic.Env({poolManager: poolManager, factory: i_factory}),
            s_hookStorage,
            underlying,
            principalToken,
            params
        );
    }

    /// @notice Deposit at most `amount0Desired` and `amount1Desired` of `key.currency0` and `key.currency1` respectively to the `key` pool
    /// If excess amount is left, it will be refunded to `refundReceiver`
    /// @dev Deposit keeps the proportion of the pool as much as possible.
    /// @dev Deposit MUST NOT pull more tokens than the amount user specified.
    /// @dev Reverts if user provided budget `amount0Desired` or `amount1Desired` is insufficient.
    /// @dev If vault is zero address, skip rehypothecation.
    /// @dev If vault charges fees, pool is initialized with a proportion slightly different from the ratio user desired.
    /// @dev If vault charges fees or the desired amount is too large, fewer amount of tokens may be pulled.
    function addLiquidity(
        PoolKey calldata key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        address receiver,
        address refundReceiver
    ) external nonReentrant returns (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent) {
        // Get pool state
        PoolStorage memory state = s_hookStorage.s_states[key.toId()];
        address pointer = state.immutableParamsPointer;

        ContractValidation.checkTokiPoolExists(pointer);
        ImmutableParams memory immutables = ImmutableParamsLib.decode.asImmutableParams()(pointer);

        LibPauseGuard.checkNotPaused(
            immutables.principalToken, immutables.pausableFlags, Constants.PAUSABLE_LP_DEPOSITS
        );
        LibExpiry.checkNotExpired(immutables.expiry);

        // Hooklet call
        HookletLib.hookletBeforeAddLiquidity(immutables.hooklet, msg.sender, key, amount0Desired, amount1Desired);

        // Transfer tokens from user, deposit into vaults and unlock PoolManager.
        DepositReturnData memory depositReturnData = _deposit(
            DepositParams({
                key: key,
                state: state,
                immutables: immutables,
                vault0: immutables.vault0,
                vault1: immutables.vault1,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                refundReceiver: refundReceiver
            })
        );

        liquidity = depositReturnData.liquidity;
        amount0Spent = depositReturnData.amount0Spent;
        amount1Spent = depositReturnData.amount1Spent;

        // -----------------------------------------------------------------
        // EFFECTS
        // -----------------------------------------------------------------

        // Emit event in separate scope to reduce stack pressure
        Events.emitHookAddLiquidity(
            PoolId.unwrap(key.toId()), msg.sender, receiver, liquidity, amount0Spent, amount1Spent
        );

        bool initializingPool = state.totalLiquidity == 0;
        uint96 initialLnImpliedRate;
        if (initializingPool) {
            // Path: initialize locked minimum liquidity before exposing state externally.
            state.totalLiquidity = LiquidityAmounts.MINIMUM_LIQUIDITY.toUint128();

            Uint128x2 initialBalances =
                Packing.pack_uint128x2(depositReturnData.amount0.toUint128(), depositReturnData.amount1.toUint128());

            TokiSwap.PoolState memory poolState = TokiSwap.PoolState({
                balances: initialBalances,
                fees: state.fees,
                lnImpliedRate: state.lnImpliedRate,
                totalLiquidity: state.totalLiquidity
            });

            initialLnImpliedRate = TokiSwap.computeInitialLnImpliedRate(poolState, immutables).toUint96();
        }

        {
            PoolKey calldata key_ = key;
            PoolStorage storage $ = s_hookStorage.s_states[key_.toId()];
            if (initializingPool) {
                $.lnImpliedRate = initialLnImpliedRate;
            }

            $.reserves = state.reserves;
            $.rawBalances = state.rawBalances;
            $.totalLiquidity = (state.totalLiquidity + liquidity).toUint128();
        }

        if (initializingPool) {
            immutables.liquidityToken.mint(address(0), LiquidityAmounts.MINIMUM_LIQUIDITY);
        }

        // Token minting after state update prevents hooklet callbacks from seeing inconsistent storage
        immutables.liquidityToken.mint(receiver, liquidity);

        // Hooklet call
        {
            PoolKey calldata key_ = key;
            HookletLib.hookletAfterAddLiquidity(
                immutables.hooklet, msg.sender, key_, liquidity, amount0Spent, amount1Spent
            );
        }
    }

    /// @param liquidity The amount of liquidity minted.
    /// @param amount0Spent The amount of currency0 spent by hook. The net amount may be fewer because of refund.
    /// @param amount1Spent The amount of currency1 spent by hook. The net amount may be fewer because of refund.
    /// @param amount0 The amount of currency0 deposited to the pool balance.
    /// @param amount1 The amount of currency1 deposited to the pool balance.
    struct DepositReturnData {
        uint256 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint256 amount0Spent;
        uint256 amount1Spent;
    }

    /// @param amount0Desired The maximum amount of currency0 desired to be deposited.
    /// @param amount1Desired The maximum amount of currency1 desired to be deposited.
    /// @param refundReceiver The address to receive the refund of excess vault shares.
    struct DepositParams {
        PoolKey key;
        PoolStorage state;
        ImmutableParams immutables;
        ERC4626 vault0;
        ERC4626 vault1;
        uint256 amount0Desired;
        uint256 amount1Desired;
        address refundReceiver;
    }

    /// @dev A hack to workaround stack too deep error. It can't be helped.
    /// @notice Handles the complex deposit logic including vault operations and deficit management
    /// @dev Reverts if user's budget allocation is insufficient.
    function _deposit(DepositParams memory params) internal returns (DepositReturnData memory returnData) {
        // Compute liquidity for given amounts based on the current balance proportion.
        Uint128x2 balances = LibRehypothecation.getTotalBalances(
            params.vault0, params.vault1, params.state.reserves, params.state.rawBalances
        );
        (, returnData.amount0, returnData.amount1) = LiquidityAmounts.getLiquidityForAmounts(
            params.amount0Desired, params.amount1Desired, balances, params.state.totalLiquidity
        );

        // Calculate deposit amounts for vaults
        uint256 depositAmount0 = LibRehypothecation.calculateDepositAmount(
            params.vault0, returnData.amount0, params.immutables.targetRawTokenRatio0
        );
        uint256 depositAmount1 = LibRehypothecation.calculateDepositAmount(
            params.vault1, returnData.amount1, params.immutables.targetRawTokenRatio1
        );

        // Transfer tokens directly from user to hook for vault deposits
        if (depositAmount0 > 0) {
            SafeTransferLib.safeTransferFrom(
                Currency.unwrap(params.key.currency0), msg.sender, address(this), depositAmount0
            );
        }

        if (depositAmount1 > 0) {
            SafeTransferLib.safeTransferFrom(
                Currency.unwrap(params.key.currency1), msg.sender, address(this), depositAmount1
            );
        }

        // Deposit into vaults
        uint256 assets0;
        uint256 assets1;
        uint256 shares0;
        uint256 shares1;

        // Edge case: Refund if any amount that vault did not spend.
        (shares0, assets0, depositAmount0) = LibRehypothecation.depositToVaultWithRefund(
            params.vault0, Currency.unwrap(params.key.currency0), depositAmount0, params.refundReceiver
        );
        (shares1, assets1, depositAmount1) = LibRehypothecation.depositToVaultWithRefund(
            params.vault1, Currency.unwrap(params.key.currency1), depositAmount1, params.refundReceiver
        );

        // Update memory state
        params.state.reserves = Packing.add(params.state.reserves, shares0.toUint128(), shares1.toUint128());

        if (shares0 > 0 || depositAmount0 > 0) {
            Events.emitVaultDeposit(
                PoolId.unwrap(params.key.toId()),
                uint256(CurrencyIndex.CURRENCY_0),
                address(params.vault0),
                depositAmount0,
                shares0
            );
        }

        if (shares1 > 0 || depositAmount1 > 0) {
            Events.emitVaultDeposit(
                PoolId.unwrap(params.key.toId()),
                uint256(CurrencyIndex.CURRENCY_1),
                address(params.vault1),
                depositAmount1,
                shares1
            );
        }

        // Adjust input amounts to take into account the vault fees.
        // Handle potential rounding errors where vault returns slightly less than deposited

        // If rehypothecation is disabled, `depositAmount0` and `assets0` will be 0.
        // Constraint: amount0 <= params.amount0Desired
        // assets0 < depositAmount0 can happen if vault takes entry or exit fee.
        // Reduce amount0 but which may result in an edge case mentioned below.
        // Dev note: an idea is making up the difference by pulling the insufficient amount from user but hooks pulls more than the amount specified in params,
        // which is not intuitive. So we don't do that.
        // At later lines, hook would pull fewer tokens1 than the desired amount to keep the proportion.
        // Otherwise, if vault returns more assets than the deposit for some reason, we're going to refund any excess to the user.
        if (assets0 < depositAmount0) {
            returnData.amount0 -= depositAmount0 - assets0;
        }

        if (assets1 < depositAmount1) {
            returnData.amount1 -= depositAmount1 - assets1;
        }

        // Recalculate liquidity for amounts (with updated amounts, taking vault fees into account).
        // Constraint: returnData.amount0 <= amount0
        (returnData.liquidity, returnData.amount0, returnData.amount1) = LiquidityAmounts.getLiquidityForAmounts(
            returnData.amount0, returnData.amount1, balances, params.state.totalLiquidity
        );

        // Take tokens that is going to lie in the pool (custodied by PoolManager) - this will call unlockCallback.
        // Hook doesn't pull more tokens than the original amount user specified.\
        uint256 rawAmount0;
        {
            uint256 refundShares0;
            (rawAmount0, refundShares0) = _calculateRefundAndRawAmount(
                CalculateRefundAndRawAmountParams({
                    vault: params.vault0,
                    shares: shares0,
                    sharesInAsset: assets0,
                    requiredAmount: returnData.amount0,
                    maximumAllowance: params.amount0Desired - depositAmount0
                })
            );

            refundShares0 = _redeemRefundShares(params, CurrencyIndex.CURRENCY_0, refundShares0);

            // Update memory state from actual redeemed shares.
            params.state.reserves = params.state.reserves.sub(refundShares0.toUint128(), 0);
        }

        uint256 rawAmount1;
        {
            uint256 refundShares1;
            (rawAmount1, refundShares1) = _calculateRefundAndRawAmount(
                CalculateRefundAndRawAmountParams({
                    vault: params.vault1,
                    shares: shares1,
                    requiredAmount: returnData.amount1,
                    sharesInAsset: assets1,
                    maximumAllowance: params.amount1Desired - depositAmount1
                })
            );

            refundShares1 = _redeemRefundShares(params, CurrencyIndex.CURRENCY_1, refundShares1);

            // Update memory state from actual redeemed shares.
            params.state.reserves = params.state.reserves.sub(0, refundShares1.toUint128());
        }

        // Update memory state
        params.state.rawBalances = params.state.rawBalances.add(rawAmount0.toUint128(), rawAmount1.toUint128());
        returnData.amount0Spent = rawAmount0 + depositAmount0;
        returnData.amount1Spent = rawAmount1 + depositAmount1;

        poolManager.unlock(
            abi.encode(
                UnlockType.LIQUIDITY_OPERATION, params.key, msg.sender, -rawAmount0.toInt128(), -rawAmount1.toInt128()
            )
        );
    }

    /// @dev A hack to workaround stack too deep error.
    struct CalculateRefundAndRawAmountParams {
        ERC4626 vault;
        uint256 shares;
        uint256 sharesInAsset;
        uint256 requiredAmount;
        uint256 maximumAllowance;
    }

    function _calculateRefundAndRawAmount(CalculateRefundAndRawAmountParams memory params)
        internal
        view
        returns (uint256 rawAmount, uint256 refundShares)
    {
        if (params.requiredAmount > params.sharesInAsset) {
            // Deficit case: need to pull additional tokens from user
            rawAmount = params.requiredAmount - params.sharesInAsset;

            // Verify we don't exceed user's original allowance
            if (rawAmount > params.maximumAllowance) {
                // Extremely rare case or mathematically never happens
                Errors.TokiHook_InsufficientInputAmount.selector.revertWith(address(params.vault));
            }
        } else {
            // Surplus case: need to refund excess vault shares
            uint256 sharesNeededForLiquidity = params.vault.previewWithdraw(params.requiredAmount);
            refundShares = FixedPointMathLib.zeroFloorSub(params.shares, sharesNeededForLiquidity);
        }
    }

    function _redeemRefundShares(DepositParams memory params, CurrencyIndex currencyIndex, uint256 refundShares)
        internal
        returns (uint256)
    {
        ERC4626 vault;
        Currency currency;
        if (currencyIndex == CurrencyIndex.CURRENCY_0) {
            vault = params.vault0;
            currency = params.key.currency0;
        } else {
            vault = params.vault1;
            currency = params.key.currency1;
        }

        (uint256 sharesRedeemed, uint256 assetsRefunded) =
            LibRehypothecation.redeemFromVault(vault, Currency.unwrap(currency), refundShares, params.refundReceiver);

        if (sharesRedeemed > 0 || assetsRefunded > 0) {
            Events.emitVaultWithdraw(
                PoolId.unwrap(params.key.toId()),
                uint256(currencyIndex),
                address(vault),
                Events.VAULT_WITHDRAW_FLOW_REFUND,
                assetsRefunded,
                sharesRedeemed
            );
        }

        return sharesRedeemed;
    }

    /// @dev Allows to remove liquidity both before- and after-expiry.
    /// @dev Reverts if vault burns more shares than the LP's pro-rata slice of `state.reserves`
    function removeLiquidity(PoolKey calldata key, uint256 liquidity, address receiver)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        // Get pool state
        PoolStorage memory state = s_hookStorage.s_states[key.toId()];
        address pointer = state.immutableParamsPointer;

        ContractValidation.checkTokiPoolExists(pointer);

        ImmutableParams memory immutables = ImmutableParamsLib.decode.asImmutableParams()(pointer);

        LibPauseGuard.checkNotPaused(
            immutables.principalToken, immutables.pausableFlags, Constants.PAUSABLE_LP_WITHDRAWALS
        );

        PreviewWithdraw memory preview;
        // Stack too deep error workaround. It can't be helped.
        {
            // Compute amounts proportional to liquidity amount
            // forgefmt: disable-start
            (uint256 rawAmount0, uint256 rawAmount1) = LiquidityAmounts.getAmountsForLiquidity(liquidity, state.totalLiquidity, state.rawBalances);
            (uint256 shares0, uint256 shares1) = LiquidityAmounts.getAmountsForLiquidity(liquidity, state.totalLiquidity, state.reserves);
            // forgefmt: disable-end

            preview =
                PreviewWithdraw({rawAmount0: rawAmount0, rawAmount1: rawAmount1, shares0: shares0, shares1: shares1});
        }

        // Hooklet call
        HookletLib.hookletBeforeRemoveLiquidity(immutables.hooklet, msg.sender, key, liquidity);

        // Send tokens to receiver - this will call unlockCallback
        poolManager.unlock(
            abi.encode(
                UnlockType.LIQUIDITY_OPERATION,
                key,
                receiver,
                preview.rawAmount0.toInt128(),
                preview.rawAmount1.toInt128()
            )
        );

        {
            (uint256 shares0Actual, uint256 assets0Actual) = LibRehypothecation.redeemFromVault(
                immutables.vault0, Currency.unwrap(key.currency0), preview.shares0, receiver
            );
            (uint256 shares1Actual, uint256 assets1Actual) = LibRehypothecation.redeemFromVault(
                immutables.vault1, Currency.unwrap(key.currency1), preview.shares1, receiver
            );

            // -----------------------------------------------------------------
            // EFFECTS
            // -----------------------------------------------------------------

            if (shares0Actual > 0 || assets0Actual > 0) {
                Events.emitVaultWithdraw(
                    PoolId.unwrap(key.toId()),
                    uint256(CurrencyIndex.CURRENCY_0),
                    address(immutables.vault0),
                    Events.VAULT_WITHDRAW_FLOW_REMOVE_LIQUIDITY,
                    assets0Actual,
                    shares0Actual
                );
            }

            if (shares1Actual > 0 || assets1Actual > 0) {
                Events.emitVaultWithdraw(
                    PoolId.unwrap(key.toId()),
                    uint256(CurrencyIndex.CURRENCY_1),
                    address(immutables.vault1),
                    Events.VAULT_WITHDRAW_FLOW_REMOVE_LIQUIDITY,
                    assets1Actual,
                    shares1Actual
                );
            }

            // Update state
            state.reserves = state.reserves.sub(shares0Actual.toUint128(), shares1Actual.toUint128());

            // Amounts withdrawn from vaults + raw amounts
            amount0 = assets0Actual + preview.rawAmount0;
            amount1 = assets1Actual + preview.rawAmount1;
        }

        // Update state
        PoolStorage storage $ = s_hookStorage.s_states[key.toId()];
        $.reserves = state.reserves;
        $.rawBalances = state.rawBalances.sub(preview.rawAmount0.toUint128(), preview.rawAmount1.toUint128());
        $.totalLiquidity = (state.totalLiquidity - liquidity).toUint128();

        // Emit event
        Events.emitHookRemoveLiquidity(PoolId.unwrap(key.toId()), msg.sender, receiver, liquidity, amount0, amount1);

        // Burn LP tokens
        immutables.liquidityToken.burn(msg.sender, liquidity);

        // Hooklet call
        HookletLib.hookletAfterRemoveLiquidity(immutables.hooklet, msg.sender, key, liquidity, amount0, amount1);
    }

    struct PreviewWithdraw {
        uint256 rawAmount0;
        uint256 rawAmount1;
        uint256 shares0;
        uint256 shares1;
    }

    enum UnlockType {
        FEE_COLLECTION,
        LIQUIDITY_OPERATION,
        VAULT_REDEMPTION
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (UnlockType unlockType) = abi.decode(data, (UnlockType));

        if (unlockType == UnlockType.FEE_COLLECTION) {
            // Send tokens to fee receiver
            (, PoolKey memory key, address feeReceiver, uint256 amount0) =
                abi.decode(data, (UnlockType, PoolKey, address, uint256));

            CurrencySettler.cashOut(poolManager, key.currency0, amount0, feeReceiver);
        } else if (unlockType == UnlockType.LIQUIDITY_OPERATION) {
            (, PoolKey memory key, address sender, int256 amount0, int256 amount1) =
                abi.decode(data, (UnlockType, PoolKey, address, int256, int256));

            // Remove liquidity if amount0 is positive
            if (amount0 > 0) {
                // Burns ERC-6909 tokens to receive tokens
                CurrencySettler.cashOut(poolManager, key.currency0, uint256(amount0), sender);
            }

            // Remove liquidity if amount1 is positive
            if (amount1 > 0) {
                // Burns ERC-6909 tokens to receive tokens
                CurrencySettler.cashOut(poolManager, key.currency1, uint256(amount1), sender);
            }

            // Add liquidity if amount0 is negative
            if (amount0 < 0) {
                // Transfer tokens from user and mint ERC-6909 tokens
                CurrencySettler.cashIn(poolManager, key.currency0, sender, uint256(-amount0));
            }

            // Add liquidity if amount1 is negative
            if (amount1 < 0) {
                // Transfer tokens from user and mint ERC-6909 tokens
                CurrencySettler.cashIn(poolManager, key.currency1, sender, uint256(-amount1));
            }
        } else if (unlockType == UnlockType.VAULT_REDEMPTION) {
            (, ERC4626 vault, Currency currency, uint256 shares) =
                abi.decode(data, (UnlockType, ERC4626, Currency, uint256));

            // Withdraw assets from vault
            (uint256 sharesRedeemed, uint256 assetsWithdrawn) =
                V4Rehypothecation.redeemClaimTokensFromVault(poolManager, vault, currency, shares);

            return abi.encode(sharesRedeemed, assetsWithdrawn);
        }
        return "";
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          Hooks                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @return returnDelta The hook's delta in specified and unspecified currencies. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    /// @dev Currency0: underlying, Currency1: principal token is assumed.
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal override nonReentrant returns (bytes4, BeforeSwapDelta, uint24) {
        return TokiHookLogic.beforeSwap(
            TokiHookLogic.Env({poolManager: poolManager, factory: i_factory}),
            s_hookStorage,
            sender,
            key,
            params,
            hookData
        );
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        virtual
        override
        returns (bytes4)
    {
        if (key.fee != 0) Errors.CustomCurveHook_FeeMustBeZero.selector.revertWith();
        return this.afterInitialize.selector;
    }

    // Disable adding liquidity through the PoolManager
    function _beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        Errors.CustomCurveHook_LiquidityOnlyViaHook.selector.revertWith();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    Curator/Protocol                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Updates vault configuration for rehypothecation management
    /// @dev This function handles four critical operations for vault configuration:
    ///      1. UPDATE_RATIOS: Modify raw/vault asset targets
    ///      2. UPDATE_VAULT: Change or remove the ERC4626 vault
    ///      3. FREEZE_RATIOS: Permanently prevent ratio updates (cannot be undone)
    ///      4. FREEZE_VAULT: Permanently prevent vault changes (cannot be undone)
    ///
    /// @dev Important notes:
    ///      - All operations are curator-only via AccessManager
    ///      - Freeze operations are PERMANENT and IRREVERSIBLE
    ///      - Setting vault to address(0) disables rehypothecation and forces 100% raw unless ratios are frozen
    ///      - Migrating to a new vault preserves existing ratios
    ///      - Freeze operations cannot be undone
    ///
    /// @param actions The actions to perform
    /// @param params ABI-encoded parameters specific to each action:
    /// `CurrencyIndex` is the index of the currency to update:
    ///        - 0: underlying
    ///        - 1: principal token
    ///
    ///        - UPDATE_RATIOS: (uint256 currencyIndex, uint16 targetRatio, uint16 maxRatio, uint16 minRatio)
    ///        - UPDATE_VAULT: (uint256 currencyIndex, address newVault)
    ///        - FREEZE_RATIOS: (uint256 currencyIndex)
    ///        - FREEZE_VAULT: (uint256 currencyIndex)
    function updateConfiguration(
        PoolKey calldata key,
        ITokiHook.UpdateConfiguration[] calldata actions,
        bytes[] calldata params
    ) external nonReentrant {
        TokiHookLogic.updateConfiguration(s_hookStorage, key, actions, params);
    }

    /// @notice Redeem shares from a vault and deposit assets to the pool
    /// @param shares The amount of shares to withdraw from the vault (type(uint256).max for redeeming all shares).
    /// Clamped by the vault's current `maxRedeem`; reverts if the vault can redeem nothing.
    function unwindVault(PoolKey calldata key, CurrencyIndex currencyIndex, uint256 shares, uint256 minAssetsOut)
        external
        nonReentrant
    {
        PoolStorage storage $ = s_hookStorage.s_states[key.toId()];
        address pointer = $.immutableParamsPointer;

        ContractValidation.checkTokiPoolExists(pointer);

        ImmutableParams memory immutables = ImmutableParamsLib.decode.asImmutableParams()(pointer);

        _checkRestricted(immutables.principalToken.i_accessManager());

        Uint128x2 reserves = $.reserves;

        address vault;
        Currency asset;
        uint256 reserve;
        if (currencyIndex == CurrencyIndex.CURRENCY_0) {
            vault = address(immutables.vault0);
            asset = key.currency0;
            reserve = reserves.value0();
        } else {
            vault = address(immutables.vault1);
            asset = key.currency1;
            reserve = reserves.value1();
        }

        if (vault == address(0)) {
            Errors.TokiHook_VaultNotSet.selector.revertWith();
        }

        // If shares is max, redeem all reserves
        shares = FixedPointMathLib.ternary(shares == type(uint256).max, reserve, shares);

        if (shares > reserve) {
            Errors.TokiHook_VaultWithdrawMoreThanReserves.selector.revertWith();
        }

        {
            uint256 maxRedeemable = ERC4626(vault).maxRedeem(address(this));

            // `minAssetsOut` can't guard this: unwinding a worthless vault to free the shares is a
            // legitimate call with `minAssetsOut == 0`, so a no-op must be told apart from a drain.
            if (shares > 0 && maxRedeemable == 0) {
                Errors.TokiHook_NoVaultRedeemCapacity.selector.revertWith();
            }
            shares = FixedPointMathLib.min(shares, maxRedeemable);
        }

        // Unlock PoolManager to redeem vault shares and deposit withdrawn assets as claim tokens
        bytes memory result = poolManager.unlock(abi.encode(UnlockType.VAULT_REDEMPTION, vault, asset, shares));
        (uint256 sharesRedeemed, uint256 assetsWithdrawn) = abi.decode(result, (uint256, uint256));

        // Slippage protection
        if (assetsWithdrawn < minAssetsOut) {
            Errors.TokiHook_InsufficientAssetsWithdrawn.selector.revertWith();
        }

        // Update state
        if (currencyIndex == CurrencyIndex.CURRENCY_0) {
            $.reserves = reserves.sub(sharesRedeemed.toUint128(), 0);
            $.rawBalances = $.rawBalances.add(assetsWithdrawn.toUint128(), 0);
        } else {
            $.reserves = reserves.sub(0, sharesRedeemed.toUint128());
            $.rawBalances = $.rawBalances.add(0, assetsWithdrawn.toUint128());
        }

        Events.emitVaultWithdraw(
            PoolId.unwrap(key.toId()),
            uint256(currencyIndex),
            vault,
            Events.VAULT_WITHDRAW_FLOW_UNWIND,
            assetsWithdrawn,
            sharesRedeemed
        );
    }

    function collectCuratorFee(PoolKey calldata key, address feeReceiver) external nonReentrant returns (uint256) {
        // Get pool state
        PoolStorage storage $ = s_hookStorage.s_states[key.toId()];
        address pointer = $.immutableParamsPointer;

        ContractValidation.checkTokiPoolExists(pointer);

        ImmutableParams memory immutables = ImmutableParamsLib.decode.asImmutableParams()(pointer);

        // Check if the caller is restricted by the access manager associated with the pool
        _checkRestricted(immutables.principalToken.i_accessManager());

        (uint128 curatorFee, uint128 protocolFee) = $.fees.unpack();

        // Update state
        $.fees = Packing.pack_uint128x2(0, protocolFee);

        // Send fees to fee receiver
        poolManager.unlock(abi.encode(UnlockType.FEE_COLLECTION, key, feeReceiver, curatorFee));

        Events.emitHookCollectCuratorFeeCollected(PoolId.unwrap(key.toId()), feeReceiver, curatorFee);

        return curatorFee;
    }

    function collectProtocolFee(PoolKey calldata key) external nonReentrant restricted returns (uint256) {
        // Get pool state
        PoolStorage storage $ = s_hookStorage.s_states[key.toId()];
        address pointer = $.immutableParamsPointer;

        ContractValidation.checkTokiPoolExists(pointer);

        (uint128 curatorFee, uint128 protocolFee) = $.fees.unpack();

        address treasury = i_factory.s_treasury();

        // Update state
        $.fees = Packing.pack_uint128x2(curatorFee, 0);

        // Send fees to fee receiver
        poolManager.unlock(abi.encode(UnlockType.FEE_COLLECTION, key, treasury, protocolFee));

        Events.emitHookProtocolFeeCollected(PoolId.unwrap(key.toId()), treasury, protocolFee);

        return protocolFee;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           Oracle                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Fetches the observations for the given secondsAgo values
    /// @dev Reverts if oracle is not initialized or requested data is too old
    function observe(PoolKey calldata key, uint32[] memory secondsAgos)
        external
        view
        nonReadReentrant
        returns (uint216[] memory lnImpliedRateCumulative)
    {
        return TokiHookLogic.observe(s_hookStorage, key, secondsAgos);
    }

    function increaseObservationsCardinalityNext(PoolKey calldata key, uint16 cardinalityNext) external nonReentrant {
        TokiHookLogic.increaseObservationsCardinalityNext(s_hookStorage, key, cardinalityNext);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            View                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Reverts if called during a re-entrant read.
    function getTotalBalances(PoolId id) external view nonReadReentrant returns (Uint128x2) {
        PoolStorage storage $ = s_hookStorage.s_states[id];
        address pointer = $.immutableParamsPointer;

        ContractValidation.checkTokiPoolExists(pointer);

        (address vault0, address vault1) = ImmutableParamsLib.getVaults(pointer);
        return LibRehypothecation.getTotalBalances({
            vault0: ERC4626(vault0),
            vault1: ERC4626(vault1),
            reserves: $.reserves,
            rawBalances: $.rawBalances
        });
    }

    function poolKeyOf(address liquidityToken) public view returns (PoolKey memory) {
        return s_hookStorage.s_poolKeyOf[liquidityToken];
    }

    function i_accessManager() public view override returns (AccessManager) {
        return i_factory.i_accessManager();
    }

    function VERSION() external pure returns (bytes32) {
        return "2.0.0";
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         Overrides                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Use TSTORE/TLOAD everywhere.
    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }
}
