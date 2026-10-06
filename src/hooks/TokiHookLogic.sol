// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Interfaces
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {ERC4626} from "solady/src/tokens/ERC4626.sol";

import {Factory} from "../Factory.sol";
import {FeeModule} from "../modules/PoolFeeModule.sol";
import {TokiPoolToken} from "../tokens/TokiPoolToken.sol";
import {PrincipalToken} from "../tokens/PrincipalToken.sol";
import {ITokiHook, ImmutableParamsLib} from "../interfaces/ITokiHook.sol";

// Libraries
import {CREATE3} from "solady/src/utils/CREATE3.sol";
import {SSTORE2} from "solady/src/utils/SSTORE2.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {PoolId, PoolKey} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import "../Types.sol";
import "../Errors.sol";
import "../Events.sol";
import "../Constants.sol" as Constants;

import {LibExpiry} from "../utils/LibExpiry.sol";
import {LibOracle} from "../utils/LibOracle.sol";
import {TokiSwap} from "../utils/TokiSwap.sol";
import {CustomRevert} from "../utils/CustomRevert.sol";
import {LibPauseGuard} from "../utils/LibPauseGuard.sol";
import {LibAccessGuard} from "../utils/LibAccessGuard.sol";
import {ModuleAccessor} from "../utils/ModuleAccessor.sol";
import {IHooklet, HookletLib} from "../utils/HookletLib.sol";
import {ContractValidation} from "../utils/ContractValidation.sol";
import {LibRehypothecation} from "../utils/LibRehypothecation.sol";
import {V4Rehypothecation} from "../utils/V4Rehypothecation.sol";
import {FunctionTypeCasts} from "../utils/FunctionTypeCasts.sol";

/// @title TokiHookLogic
/// @notice Library for handling TokiHook deposit operations
/// @dev Extracted from TokiHook to reduce contract size
library TokiHookLogic {
    using ModuleAccessor for address[];
    using LibOracle for *;
    using SafeCastLib for *;
    using CustomRevert for *;
    using FunctionTypeCasts for *;

    struct Env {
        IPoolManager poolManager;
        Factory factory;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      DEPLOYMENT LOGIC                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function deploy(
        Env calldata env,
        ITokiHook.HookStorage storage $,
        address underlying,
        address principalToken,
        ITokiHook.TokiPoolDeploymentParams calldata params
    ) external returns (PoolKey memory poolKey, address liquidityToken) {
        // Check if caller is valid pool deployer
        if (!env.factory.s_poolDeployers(msg.sender)) Errors.TokiHook_OnlyPoolDeployer.selector.revertWith();

        // Immutable params
        ITokiHook.ImmutableParams memory immutables;

        // Check if vault is valid
        LibRehypothecation.validateVault(params.vault0, underlying);
        LibRehypothecation.validateVault(params.vault1, principalToken);
        immutables.vault0 = params.vault0;
        immutables.vault1 = params.vault1;

        // Check if vault params are valid
        {
            (uint16 vaultFlags0, uint16 targetRawTokenRatio0, uint16 maxRawTokenRatio0, uint16 minRawTokenRatio0) =
                abi.decode(params.vault0Params, (uint16, uint16, uint16, uint16));

            LibRehypothecation.validateRehypothecationParams(targetRawTokenRatio0, maxRawTokenRatio0, minRawTokenRatio0);

            immutables.vaultFlags0 = vaultFlags0;
            immutables.targetRawTokenRatio0 = targetRawTokenRatio0;
            immutables.maxRawTokenRatio0 = maxRawTokenRatio0;
            immutables.minRawTokenRatio0 = minRawTokenRatio0;
        }

        {
            (uint16 vaultFlags1, uint16 targetRawTokenRatio1, uint16 maxRawTokenRatio1, uint16 minRawTokenRatio1) =
                abi.decode(params.vault1Params, (uint16, uint16, uint16, uint16));

            LibRehypothecation.validateRehypothecationParams(targetRawTokenRatio1, maxRawTokenRatio1, minRawTokenRatio1);

            immutables.vaultFlags1 = vaultFlags1;
            immutables.targetRawTokenRatio1 = targetRawTokenRatio1;
            immutables.maxRawTokenRatio1 = maxRawTokenRatio1;
            immutables.minRawTokenRatio1 = minRawTokenRatio1;
        }

        // Check if pool fee module is set
        {
            address poolFeeModule =
                ModuleAccessor.read(PrincipalToken(principalToken).s_modules()).getOrDefault(POOL_FEE_MODULE_INDEX);
            if (poolFeeModule == address(0)) Errors.TokiHook_MissingPoolFeeModule.selector.revertWith(); // Sanity check
        }

        // Check if hook params are valid
        uint16 requestedCardinalityNext;
        {
            (uint16 cardinalityNext, bytes memory ammParams) = abi.decode(params.hookParams, (uint16, bytes));
            (uint256 scalarRoot, int256 initialAnchor) = abi.decode(ammParams, (uint256, int256));
            if (scalarRoot == 0) Errors.TokiHook_InvalidScalarRoot.selector.revertWith();
            if (initialAnchor < TokiSwap.IWAD) {
                Errors.TokiHook_InitialAnchorTooLow.selector.revertWith();
            }

            requestedCardinalityNext = cardinalityNext;
            immutables.scalarRoot = scalarRoot;
            immutables.initialAnchor = initialAnchor;
        }

        // Hooklet call
        HookletLib.hookletBeforeInitialize(params.hooklet, msg.sender, params);

        // Deploy liquidity token
        bytes memory initCode = LibClone.initCode(
            params.liquidityTokenImplementation,
            abi.encode(
                this,
                underlying,
                principalToken,
                params.pausableFlags,
                params.hooklet,
                params.liquidityTokenImmutableData
            )
        );
        liquidityToken = CREATE3.deployDeterministic(initCode, params.salt);
        TokiPoolToken(liquidityToken).initialize();

        // Set immutable params
        immutables.liquidityToken = TokiPoolToken(liquidityToken);
        immutables.principalToken = PrincipalToken(principalToken);
        immutables.underlying = underlying;
        immutables.expiry = PrincipalToken(principalToken).maturity();
        immutables.pausableFlags = params.pausableFlags;
        immutables.hooklet = params.hooklet;

        // Currency0: underlying, Currency1: principal token
        poolKey = PoolKey(Currency.wrap(underlying), Currency.wrap(principalToken), 0, 1, IHooks(address(this)));
        env.poolManager.initialize(poolKey, Constants.CUSTOM_CURVE_INITIAL_SQRT_PRICE);

        // Update state
        PoolId id = poolKey.toId();
        $.s_poolKeyOf[liquidityToken] = poolKey;
        $.s_states[id].immutableParamsPointer = SSTORE2.write(abi.encode(immutables));

        // Initialize oracle with the first observation
        ($.s_states[id].observationCardinality, $.s_states[id].observationCardinalityNext) =
            LibOracle.initialize($.s_observations[id], uint32(block.timestamp));

        // Grow oracle if needed
        if (requestedCardinalityNext > 1) {
            $.s_states[id].observationCardinalityNext =
                LibOracle.grow($.s_observations[id], 1, requestedCardinalityNext);
        }

        // Emit event
        Events.emitPoolDeployed(PoolId.unwrap(poolKey.toId()), liquidityToken);

        // Hooklet call
        HookletLib.hookletAfterInitialize(params.hooklet, msg.sender, poolKey, liquidityToken, params);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         SWAP LOGIC                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function beforeSwap(
        Env calldata env,
        ITokiHook.HookStorage storage $,
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId id = key.toId();
        ITokiHook.PoolStorage memory state = $.s_states[id];

        // Get pool state
        ContractValidation.checkTokiPoolExists(state.immutableParamsPointer);

        ITokiHook.ImmutableParams memory immutables =
            ImmutableParamsLib.decode.asImmutableParams()(state.immutableParamsPointer);

        // Check if pool is paused
        LibPauseGuard.checkNotPaused(immutables.principalToken, immutables.pausableFlags, Constants.PAUSABLE_LP_SWAPS);

        // Check if pool is expired
        LibExpiry.checkNotExpired(immutables.expiry);

        // Hooklet call
        HookletLib.hookletBeforeSwap(immutables.hooklet, sender, key, params.zeroForOne, params.amountSpecified);

        // Compute swap result and update token account balances and fees in memory state
        (BeforeSwapDelta returnDelta, SwapResult memory result) = _swap(env, key, params, hookData, state, immutables);

        {
            ITokiHook.PoolStorage storage $state = $.s_states[id];

            // Write state to storage: any state updates must be blocked by reentrancy guard
            // Update oracle
            _updateOracle($.s_observations[id], state, $state.lnImpliedRate);

            Uint128x2 fees = state.fees.add(0, result.remaining0.toUint128());
            Uint128x2 prevFees = $state.fees;

            $state.reserves = state.reserves;
            $state.rawBalances = state.rawBalances;
            $state.fees = fees;
            $state.lnImpliedRate = state.lnImpliedRate;
            $state.observationCardinality = state.observationCardinality;
            $state.observationIndex = state.observationIndex;

            Uint128x2 feesDelta = fees.sub(prevFees.value0(), prevFees.value1());

            Events.emitHookFeesAccrued(PoolId.unwrap(id), feesDelta.value0(), feesDelta.value1());
        }

        {
            address _sender = sender; // Stack too deep workaround
            PoolKey calldata _key = key;

            // Emit event
            Events.emitHookSwap({
                poolId: PoolId.unwrap(_key.toId()),
                sender: _sender,
                amount0: result.amount0.toInt128(),
                amount1: result.amount1.toInt128(),
                hookLPfeeAmount0: (result.swapFee - result.fees).toUint128(),
                hookLPfeeAmount1: 0
            });

            // Hooklet call
            HookletLib.hookletAfterSwap(
                immutables.hooklet, _sender, _key, result.amount0, result.amount1, state.lnImpliedRate
            );
        }

        return (IHooks.beforeSwap.selector, returnDelta, 0);
    }

    /// @notice Updates the oracle state
    /// @param state new state of the pool
    /// @param lastLnImpliedRate last ln(impliedRate) right before the current swap is executed
    function _updateOracle(
        LibOracle.Observation[65535] storage $,
        ITokiHook.PoolStorage memory state,
        uint96 lastLnImpliedRate
    ) internal {
        (uint16 observationIndex, uint16 observationCardinality) = $.write(
            state.observationIndex,
            uint32(block.timestamp),
            lastLnImpliedRate,
            state.observationCardinality,
            state.observationCardinalityNext
        );
        state.observationIndex = observationIndex;
        state.observationCardinality = observationCardinality;
    }

    /// @dev Output of the TokiSwap.swap() function
    struct SwapResult {
        int256 amount0;
        int256 amount1;
        uint256 swapFee;
        uint256 fees; // fees going to protocol and curator
        uint256 remaining0; // difference between the specified amount and the actual amount spent on currency0
    }

    /// @dev Revert if module not found
    /// @dev Revert if vaults revert
    /// @dev Revert if swap calculation fails
    function _swap(
        Env calldata env,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData,
        ITokiHook.PoolStorage memory state,
        ITokiHook.ImmutableParams memory immutables
    ) internal returns (BeforeSwapDelta returnDelta, SwapResult memory result) {
        // Compute swap result
        {
            // vault.previewRedeem(reserves) + rawBalances
            Uint128x2 balances = LibRehypothecation.getTotalBalances(
                immutables.vault0, immutables.vault1, state.reserves, state.rawBalances
            );

            TokiSwap.PoolState memory swapState = TokiSwap.PoolState({
                balances: balances,
                fees: state.fees,
                lnImpliedRate: state.lnImpliedRate,
                totalLiquidity: state.totalLiquidity
            });

            ApproximationParams memory approx = decodeApproximationParamsStruct(hookData);
            FeePctsPool feePcts =
                FeeModule(env.factory.moduleFor(address(immutables.principalToken), POOL_FEE_MODULE_INDEX)).getFeePcts(); // Revert if module not found

            (result.amount0, result.amount1, result.swapFee, result.fees) =
                TokiSwap.swap(swapState, immutables, params, approx, feePcts);

            // Update memory state
            // Since `PoolState.balances` comes from `state.reserves` and `state.rawBalances`,
            // actually later, we have to update `state.reserves` and `state.rawBalances` respectively
            // to ensure the state is consistent with the swap result
            state.lnImpliedRate = swapState.lnImpliedRate;
            state.fees = swapState.fees;
        }

        // Process accounting via claim tokens
        {
            // Swap result is negative - Paid by user, Positive - Received by user
            int128 amount0 = result.amount0.toInt128();
            int128 amount1 = result.amount1.toInt128();

            if (params.zeroForOne) {
                // toBeforeSwapDelta() assumes Positive - Spent by user, Negative - Received by user

                int128 claimAmount0;
                // zeroForOne: currency0 (underlying) -> currency1 (PT)
                if (params.amountSpecified < 0) {
                    // Exact input: currency0 is specified
                    // Important note: For an exact-in swap on `currency0`, the actual amount spent (`amount0`) can end up slightly less than the amount specified by the user because the swap relies on a binary search.
                    // The remaining portion would otherwise trigger the heavier Uniswap V4 concentrated-liquidity math.
                    // The negligible amount of currency0 goes to the protocol. The magnitude of the loss depends on the EPS specified.
                    claimAmount0 = -params.amountSpecified.toInt128();
                    returnDelta = toBeforeSwapDelta(claimAmount0, -amount1);

                    result.remaining0 = (claimAmount0 + amount0).toUint256();
                } else {
                    // Exact output: currency1 is specified
                    claimAmount0 = -amount0;
                    returnDelta = toBeforeSwapDelta(-amount1, claimAmount0);
                }

                // Take input by minting claim tokens
                env.poolManager.mint(address(this), key.currency0.toId(), claimAmount0.toUint256());

                // Withdraw from vault1 if the current raw balances are less than the desired output
                if (state.rawBalances.value1() < amount1.toUint256()) {
                    // If vault experienced large losses, vault can't afford to withdraw assets. There is not much we can do.
                    // Note: the burned shares are measured, and a burn exceeding `state.reserves` reverts below.
                    // So, other pools using same vaults are not affected.
                    (uint256 shares, uint256 assetsActual) = V4Rehypothecation.withdrawClaimTokensFromVault(
                        env.poolManager,
                        immutables.vault1,
                        key.currency1,
                        amount1.toUint256() - state.rawBalances.value1()
                    );

                    if (shares > state.reserves.value1()) {
                        Errors.TokiHook_VaultWithdrawMoreThanReserves.selector.revertWith();
                    }
                    // Update memory state for currency1
                    state.reserves = state.reserves.sub(0, shares.toUint128());
                    state.rawBalances = state.rawBalances.add(0, assetsActual.toUint128());

                    if (shares > 0 || assetsActual > 0) {
                        Events.emitVaultWithdraw(
                            PoolId.unwrap(key.toId()),
                            uint256(ITokiHook.CurrencyIndex.CURRENCY_1),
                            address(immutables.vault1),
                            Events.VAULT_WITHDRAW_FLOW_SWAP_JIT,
                            assetsActual,
                            shares
                        );
                    }
                }

                // Burn output claim tokens
                env.poolManager.burn(address(this), key.currency1.toId(), amount1.toUint256());
            } else {
                // !zeroForOne: currency1 (PT) -> currency0 (underlying)
                if (params.amountSpecified < 0) {
                    // Exact input: currency1 is specified
                    returnDelta = toBeforeSwapDelta(-amount1, -amount0);
                } else {
                    // Exact output: currency0 is specified
                    Errors.TokiHook_NotImplemented.selector.revertWith();
                }

                // Take input by minting claim tokens
                env.poolManager.mint(address(this), key.currency1.toId(), (-amount1).toUint256());

                // Withdraw from vault0 if the current raw balances are less than the desired output
                // Note: fees must be deducted from the raw balance because selling PT pays fees from the pool balance.
                uint256 amount0WithFees = amount0.toUint256() + result.fees;
                if (state.rawBalances.value0() < amount0WithFees) {
                    (uint256 shares, uint256 assetsActual) = V4Rehypothecation.withdrawClaimTokensFromVault(
                        env.poolManager, immutables.vault0, key.currency0, amount0WithFees - state.rawBalances.value0()
                    );

                    if (shares > state.reserves.value0()) {
                        Errors.TokiHook_VaultWithdrawMoreThanReserves.selector.revertWith();
                    }
                    // Update memory state for currency0
                    state.reserves = state.reserves.sub(shares.toUint128(), 0);
                    state.rawBalances = state.rawBalances.add(assetsActual.toUint128(), 0);

                    if (shares > 0 || assetsActual > 0) {
                        Events.emitVaultWithdraw(
                            PoolId.unwrap(key.toId()),
                            uint256(ITokiHook.CurrencyIndex.CURRENCY_0),
                            address(immutables.vault0),
                            Events.VAULT_WITHDRAW_FLOW_SWAP_JIT,
                            assetsActual,
                            shares
                        );
                    }
                }

                // Burn output claim tokens
                env.poolManager.burn(address(this), key.currency0.toId(), amount0.toUint256());
            }

            // Update raw balances based on swap result
            (uint256 rawBalance0, uint256 rawBalance1) = state.rawBalances.unpack();
            state.rawBalances = Packing.pack_uint128x2(
                (rawBalance0.toInt256() - amount0 - result.fees.toInt256()).toUint256().toUint128(),
                (rawBalance1.toInt256() - amount1).toUint256().toUint128()
            );
        }

        // Update raw token balances if we're using vaults and the (rawBalance / balance) ratio is outside the bounds
        {
            (uint256 newReserve0, uint256 newRawBalance0) = _rebalance(
                RebalanceParams({
                    poolManager: env.poolManager,
                    vault: immutables.vault0,
                    currency: key.currency0,
                    poolId: PoolId.unwrap(key.toId()),
                    currencyIndex: uint256(ITokiHook.CurrencyIndex.CURRENCY_0),
                    reserve: state.reserves.value0(),
                    rawBalance: state.rawBalances.value0(),
                    targetRawTokenRatio: immutables.targetRawTokenRatio0,
                    maxRawTokenRatio: immutables.maxRawTokenRatio0,
                    minRawTokenRatio: immutables.minRawTokenRatio0
                })
            );

            (uint256 newReserve1, uint256 newRawBalance1) = _rebalance(
                RebalanceParams({
                    poolManager: env.poolManager,
                    vault: immutables.vault1,
                    currency: key.currency1,
                    poolId: PoolId.unwrap(key.toId()),
                    currencyIndex: uint256(ITokiHook.CurrencyIndex.CURRENCY_1),
                    reserve: state.reserves.value1(),
                    rawBalance: state.rawBalances.value1(),
                    targetRawTokenRatio: immutables.targetRawTokenRatio1,
                    maxRawTokenRatio: immutables.maxRawTokenRatio1,
                    minRawTokenRatio: immutables.minRawTokenRatio1
                })
            );

            state.reserves = Packing.pack_uint128x2(newReserve0.toUint128(), newReserve1.toUint128());
            state.rawBalances = Packing.pack_uint128x2(newRawBalance0.toUint128(), newRawBalance1.toUint128());
        }
    }

    struct RebalanceParams {
        IPoolManager poolManager;
        ERC4626 vault;
        Currency currency;
        bytes32 poolId;
        uint256 currencyIndex;
        uint256 reserve;
        uint256 rawBalance;
        uint256 targetRawTokenRatio;
        uint256 maxRawTokenRatio;
        uint256 minRawTokenRatio;
    }

    /// @dev Maintain rehypothecation health by rebalancing vaults
    /// @dev If vault is zero address, no rebalance is performed
    /// @dev If the (rawBalance / balance) ratio is within bounds, no rebalance is performed
    function _rebalance(RebalanceParams memory params) internal returns (uint256 newReserve, uint256 newRawBalance) {
        // No vault, no rebalance
        if (address(params.vault) == address(0)) return (params.reserve, params.rawBalance);

        (uint256 targetRawBalance, uint256 minRawBalance, uint256 maxRawBalance) = LibRehypothecation
            .calculateRawBalanceBounds({
            balance: params.rawBalance + LibRehypothecation.getReservesInUnderlying(params.vault, params.reserve),
            targetRawTokenRatio: params.targetRawTokenRatio,
            maxRawTokenRatio: params.maxRawTokenRatio,
            minRawTokenRatio: params.minRawTokenRatio
        });

        // No rebalance needed if within bounds
        if (params.rawBalance > minRawBalance && params.rawBalance < maxRawBalance) {
            return (params.reserve, params.rawBalance);
        }

        // If out of bounds, rebalance
        if (targetRawBalance > params.rawBalance) {
            uint256 rebalanceAmount =
                FixedPointMathLib.min(targetRawBalance - params.rawBalance, params.vault.maxWithdraw(address(this)));
            (uint256 shares, uint256 assetsWithdrawn) = V4Rehypothecation.withdrawClaimTokensFromVault(
                params.poolManager, params.vault, params.currency, rebalanceAmount
            );

            // Revert if vault tries to withdraw more shares than its reserves
            if (shares > params.reserve) {
                Errors.TokiHook_VaultWithdrawMoreThanReserves.selector.revertWith();
            }

            newReserve = params.reserve - shares;
            newRawBalance = params.rawBalance + assetsWithdrawn;

            if (shares > 0 || assetsWithdrawn > 0) {
                Events.emitVaultWithdraw(
                    params.poolId,
                    params.currencyIndex,
                    address(params.vault),
                    Events.VAULT_WITHDRAW_FLOW_REBALANCE,
                    assetsWithdrawn,
                    shares
                );
            }
        } else {
            uint256 rebalanceAmount = params.rawBalance - targetRawBalance;
            (uint256 shares, uint256 assetsSpent) = V4Rehypothecation.depositClaimTokensToVault(
                params.poolManager, params.vault, params.currency, rebalanceAmount
            );

            newReserve = params.reserve + shares;
            newRawBalance = params.rawBalance - assetsSpent;

            if (shares > 0 || assetsSpent > 0) {
                Events.emitVaultDeposit(params.poolId, params.currencyIndex, address(params.vault), assetsSpent, shares);
            }
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          Oracle                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Fetches the observations for the given secondsAgo values
    /// @dev Reverts if oracle is not initialized or requested data is too old
    function observe(ITokiHook.HookStorage storage $, PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (uint216[] memory lnImpliedRateCumulative)
    {
        PoolId id = key.toId();
        ITokiHook.PoolStorage storage $state = $.s_states[id];

        // Check if pool exists
        ContractValidation.checkTokiPoolExists($state.immutableParamsPointer);

        // Get observations
        lnImpliedRateCumulative = LibOracle.observe(
            $.s_observations[id],
            uint32(block.timestamp),
            secondsAgos,
            $state.lnImpliedRate,
            $state.observationIndex,
            $state.observationCardinality
        );
    }

    function increaseObservationsCardinalityNext(
        ITokiHook.HookStorage storage $,
        PoolKey calldata key,
        uint16 cardinalityNext
    ) external {
        PoolId id = key.toId();
        ITokiHook.PoolStorage storage $state = $.s_states[id];
        ContractValidation.checkTokiPoolExists($state.immutableParamsPointer);

        $state.observationCardinalityNext = LibOracle.grow({
            self: $.s_observations[id],
            current: $state.observationCardinalityNext,
            next: cardinalityNext
        });
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       Curator/Protocol                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function updateConfiguration(
        ITokiHook.HookStorage storage $,
        PoolKey calldata key,
        ITokiHook.UpdateConfiguration[] calldata actions,
        bytes[] calldata params
    ) external {
        // Check if array lengths match
        require(actions.length == params.length);

        ITokiHook.PoolStorage storage $state = $.s_states[key.toId()];
        address pointer = $state.immutableParamsPointer;

        // Check if pool exists
        ContractValidation.checkTokiPoolExists(pointer);

        ITokiHook.ImmutableParams memory immutables = ImmutableParamsLib.decode.asImmutableParams()(pointer);

        // Check if the caller is restricted by the access manager associated with the pool
        // Use TokiHook.updateConfiguration selector since this is called via delegatecall
        LibAccessGuard.checkRestricted(
            immutables.principalToken.i_accessManager(), ITokiHook.updateConfiguration.selector
        );

        // Check if pool is paused
        LibPauseGuard.checkNotPaused(
            immutables.principalToken, immutables.pausableFlags, Constants.PAUSABLE_CONFIGURATION_UPDATE
        );

        Uint128x2 reserves = $state.reserves;

        // Store original vaults to check for changes
        ERC4626 originalVault0 = immutables.vault0;
        ERC4626 originalVault1 = immutables.vault1;

        for (uint256 i = 0; i < actions.length; i++) {
            if (actions[i] == ITokiHook.UpdateConfiguration.UPDATE_RATIOS) {
                immutables = _updateRatios(key, immutables, params[i]);
            } else if (actions[i] == ITokiHook.UpdateConfiguration.UPDATE_VAULT) {
                immutables = _updateVault(key, immutables, params[i]);
            } else if (actions[i] == ITokiHook.UpdateConfiguration.FREEZE_RATIOS) {
                immutables = _freezeRatios(key, immutables, params[i]);
            } else if (actions[i] == ITokiHook.UpdateConfiguration.FREEZE_VAULT) {
                immutables = _freezeVault(key, immutables, params[i]);
            }
        }
        // Invariant: vaults must not change if they have assets
        if (immutables.vault0 != originalVault0 && reserves.value0() > 0) {
            Errors.TokiHook_VaultHasAssets.selector.revertWith();
        }
        if (immutables.vault1 != originalVault1 && reserves.value1() > 0) {
            Errors.TokiHook_VaultHasAssets.selector.revertWith();
        }

        // Write new immutable params
        $state.immutableParamsPointer = SSTORE2.write(abi.encode(immutables));
    }

    /// @notice Processes ratio updates
    function _updateRatios(PoolKey calldata key, ITokiHook.ImmutableParams memory immutables, bytes calldata params)
        internal
        returns (ITokiHook.ImmutableParams memory)
    {
        bytes32 poolId = PoolId.unwrap(key.toId());

        (
            ITokiHook.CurrencyIndex currencyIndex,
            uint16 targetRawTokenRatio,
            uint16 maxRawTokenRatio,
            uint16 minRawTokenRatio
        ) = abi.decode(params, (ITokiHook.CurrencyIndex, uint16, uint16, uint16));

        // Check params
        LibRehypothecation.validateRehypothecationParams(targetRawTokenRatio, maxRawTokenRatio, minRawTokenRatio);

        // Emit event
        Events.emitVaultRatiosUpdated(
            poolId, uint256(currencyIndex), targetRawTokenRatio, maxRawTokenRatio, minRawTokenRatio
        );

        if (currencyIndex == ITokiHook.CurrencyIndex.CURRENCY_0) {
            // Check if vault is frozen
            LibRehypothecation.validateParamsFrozen(immutables.vaultFlags0);

            immutables.targetRawTokenRatio0 = targetRawTokenRatio;
            immutables.maxRawTokenRatio0 = maxRawTokenRatio;
            immutables.minRawTokenRatio0 = minRawTokenRatio;
        } else {
            LibRehypothecation.validateParamsFrozen(immutables.vaultFlags1);

            immutables.targetRawTokenRatio1 = targetRawTokenRatio;
            immutables.maxRawTokenRatio1 = maxRawTokenRatio;
            immutables.minRawTokenRatio1 = minRawTokenRatio;
        }

        return immutables;
    }

    /// @notice Processes vault updates
    function _updateVault(PoolKey calldata key, ITokiHook.ImmutableParams memory immutables, bytes calldata params)
        internal
        returns (ITokiHook.ImmutableParams memory)
    {
        bytes32 poolId = PoolId.unwrap(key.toId());

        (ITokiHook.CurrencyIndex currencyIndex, ERC4626 newVault) =
            abi.decode(params, (ITokiHook.CurrencyIndex, ERC4626));

        ERC4626 oldVault;
        bool ratiosReset;
        if (currencyIndex == ITokiHook.CurrencyIndex.CURRENCY_0) {
            // Check if vault is valid
            LibRehypothecation.validateVault(newVault, Currency.unwrap(key.currency0));
            LibRehypothecation.validateVaultFrozen(immutables.vaultFlags0);

            // Update vault and reset ratios if vault is removed and ratios are not frozen
            oldVault = immutables.vault0;
            immutables.vault0 = newVault;
            if (address(newVault) == address(0) && !LibRehypothecation.isParamsFrozen(immutables.vaultFlags0)) {
                immutables.targetRawTokenRatio0 = uint16(Constants.BASIS_POINTS);
                immutables.maxRawTokenRatio0 = uint16(Constants.BASIS_POINTS);
                immutables.minRawTokenRatio0 = uint16(Constants.BASIS_POINTS);
                ratiosReset = true;
            }
        } else {
            // Check if vault is valid
            LibRehypothecation.validateVault(newVault, Currency.unwrap(key.currency1));
            LibRehypothecation.validateVaultFrozen(immutables.vaultFlags1);

            // Update vault and reset ratios if vault is removed and ratios are not frozen
            oldVault = immutables.vault1;
            immutables.vault1 = newVault;
            if (address(newVault) == address(0) && !LibRehypothecation.isParamsFrozen(immutables.vaultFlags1)) {
                immutables.targetRawTokenRatio1 = uint16(Constants.BASIS_POINTS);
                immutables.maxRawTokenRatio1 = uint16(Constants.BASIS_POINTS);
                immutables.minRawTokenRatio1 = uint16(Constants.BASIS_POINTS);
                ratiosReset = true;
            }
        }

        if (ratiosReset) {
            Events.emitVaultRatiosUpdated(
                poolId,
                uint256(currencyIndex),
                uint16(Constants.BASIS_POINTS),
                uint16(Constants.BASIS_POINTS),
                uint16(Constants.BASIS_POINTS)
            );
        }

        Events.emitVaultUpdated(poolId, uint256(currencyIndex), address(oldVault), address(newVault));

        return immutables;
    }

    /// @notice Processes ratio freezing
    function _freezeRatios(PoolKey calldata key, ITokiHook.ImmutableParams memory immutables, bytes calldata params)
        internal
        returns (ITokiHook.ImmutableParams memory)
    {
        bytes32 poolId = PoolId.unwrap(key.toId());

        (ITokiHook.CurrencyIndex currencyIndex) = abi.decode(params, (ITokiHook.CurrencyIndex));

        Events.emitVaultRatiosFrozen(poolId, uint256(currencyIndex));

        if (currencyIndex == ITokiHook.CurrencyIndex.CURRENCY_0) {
            immutables.vaultFlags0 |= Constants.REHYPO_RATIOS_FROZEN;
        } else {
            immutables.vaultFlags1 |= Constants.REHYPO_RATIOS_FROZEN;
        }

        return immutables;
    }

    /// @notice Processes vault freezing
    function _freezeVault(PoolKey calldata key, ITokiHook.ImmutableParams memory immutables, bytes calldata params)
        internal
        returns (ITokiHook.ImmutableParams memory)
    {
        bytes32 poolId = PoolId.unwrap(key.toId());

        (ITokiHook.CurrencyIndex currencyIndex) = abi.decode(params, (ITokiHook.CurrencyIndex));

        Events.emitVaultFrozen(poolId, uint256(currencyIndex));

        if (currencyIndex == ITokiHook.CurrencyIndex.CURRENCY_0) {
            immutables.vaultFlags0 |= Constants.REHYPO_VAULT_FROZEN;
        } else {
            immutables.vaultFlags1 |= Constants.REHYPO_VAULT_FROZEN;
        }

        return immutables;
    }
}
