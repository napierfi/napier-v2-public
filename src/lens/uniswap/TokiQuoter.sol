// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {ERC4626} from "solady/src/tokens/ERC4626.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import {Factory} from "../../Factory.sol";
import {PrincipalToken} from "../../tokens/PrincipalToken.sol";
import {TokiPoolToken} from "../../tokens/TokiPoolToken.sol";
import {ITokiHook, ImmutableParamsLib, StateLibrary} from "../../interfaces/ITokiHook.sol";
import {PoolFeeModule} from "../../modules/PoolFeeModule.sol";
import {TokiPoolDeployer} from "../../modules/deployers/TokiPoolDeployer.sol";

import "../../Types.sol";
import "../../Errors.sol";
import "../../Constants.sol" as Constants;
import {ContractValidation} from "../../utils/ContractValidation.sol";
import {LibExpiry} from "../../utils/LibExpiry.sol";
import {LibPauseGuard} from "../../utils/LibPauseGuard.sol";
import {LibOracle} from "../../utils/LibOracle.sol";
import {LibRehypothecation} from "../../utils/LibRehypothecation.sol";
import {FunctionTypeCasts} from "../../utils/FunctionTypeCasts.sol";
import {LiquidityAmounts} from "../../utils/LiquidityAmounts.sol";
import {TokiSwap} from "../../utils/TokiSwap.sol";
import {TokiSwapBinSearch} from "../../utils/TokiSwapBinSearch.sol";
import {LibBlueprint} from "../../utils/LibBlueprint.sol";

import {AccessManaged, AccessManager} from "../../modules/AccessManager.sol";
import {PrincipalTokenQuoter} from "../PrincipalTokenQuoter.sol";

/// @dev ERC1967I Immutable args: abi.encode(swapBinSearch, tokiPoolDeployer, principalTokenQuoter)
contract TokiQuoter is AccessManaged, UUPSUpgradeable, Initializable {
    using SafeCastLib for *;
    using FunctionTypeCasts for *;

    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address newImplementation) internal override restricted {}

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           View                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function i_accessManager() public view override returns (AccessManager) {
        (,, PrincipalTokenQuoter i_principalTokenQuoter) = _parseImmutableArgs();
        return i_principalTokenQuoter.i_accessManager();
    }

    function principalTokenQuoter() public view returns (PrincipalTokenQuoter) {
        (,, PrincipalTokenQuoter i_principalTokenQuoter) = _parseImmutableArgs();
        return i_principalTokenQuoter;
    }

    function getImmutableArgs()
        external
        view
        returns (
            TokiSwapBinSearch i_tokiSwapBinSearch,
            TokiPoolDeployer i_tokiPoolDeployer,
            PrincipalTokenQuoter i_principalTokenQuoter
        )
    {
        (i_tokiSwapBinSearch, i_tokiPoolDeployer, i_principalTokenQuoter) = _parseImmutableArgs();
    }

    /// @dev No check performed for pool key
    function getTokenInList(address pool) public view returns (Token[] memory) {
        PoolKey memory key = TokiPoolToken(pool).i_poolKey();
        (,, PrincipalTokenQuoter i_principalTokenQuoter) = _parseImmutableArgs();
        return i_principalTokenQuoter.getTokenInList(PrincipalToken(Currency.unwrap(key.currency1)));
    }

    /// @dev No check performed for pool key
    function getTokenOutList(address pool) public view returns (Token[] memory) {
        PoolKey memory key = TokiPoolToken(pool).i_poolKey();
        (,, PrincipalTokenQuoter i_principalTokenQuoter) = _parseImmutableArgs();
        return i_principalTokenQuoter.getTokenOutList(PrincipalToken(Currency.unwrap(key.currency1)));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         Split Quote                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function quoteSplitUnderlyingTokenLiquidityKeepYt(PoolKey memory key, uint256 amount0Desired)
        public
        view
        checkPoolKey(key)
        returns (uint256 amount0ToTokenize, uint256 amount1Out)
    {
        PrincipalToken pt = PrincipalToken(Currency.unwrap(key.currency1));

        // Guard: issuance unavailable when PT is paused or expired
        ITokiHook.ImmutableParams memory immutables =
            ImmutableParamsLib.decodeFor.asImmutableParams()(ITokiHook(address(key.hooks)), key.toId());
        _revertIfIssuanceDisabled(immutables);

        Uint128x2 balances = ITokiHook(address(key.hooks)).getTotalBalances(key.toId());

        uint256 cscale = pt.i_resolver().scale();
        uint256 maxscale = pt.getSnapshot().maxscale;
        if (cscale > maxscale) maxscale = cscale;

        amount0ToTokenize = (amount0Desired * balances.value1())
            / (balances.value1() + TokiSwap.convertToAssets(balances.value0(), maxscale));
        amount1Out = pt.previewSupply(amount0ToTokenize);
    }

    function quoteSplitUnderlyingTokenLiquidityNoYt(
        PoolKey memory key,
        uint256 amount0Desired,
        ApproximationParams calldata approx
    ) public view checkPoolKey(key) returns (uint256, uint256, uint256, uint256) {
        (TokiSwapBinSearch i_tokiSwapBinSearch,,) = _parseImmutableArgs();

        // Find the optimal amount of PT to be sold to add liquidity with a single token but without issuing YTs
        (
            int256 bestUnderlying,
            int256 bestPt, // Positive
            uint256 _swapFee,
            uint256 _feeToCuratorAndProtocol
        ) = i_tokiSwapBinSearch.computeSwapExactPrincipalToAddLiquidity(key, amount0Desired, approx);

        return (uint256(-bestUnderlying), uint256(bestPt), _swapFee, _feeToCuratorAndProtocol);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          Pool Quote                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    struct PreviewAddLiquidityResult {
        uint256 amount0Spent;
        uint256 amount1Spent;
        uint256 liquidity;
        int256 spotExchangeRateBefore;
        int256 executionExchangeRate;
        int256 priceImpact;
    }

    function getLiquidityForAmounts(PoolKey memory key, uint256 amount0Desired, uint256 amount1Desired)
        public
        view
        checkPoolKey(key)
        returns (uint256 liquidity, uint256 amount0, uint256 amount1)
    {
        ITokiHook hook = ITokiHook(address(key.hooks));
        uint256 totalLiquidity = StateLibrary.getLiquidity(hook, key.toId());
        Uint128x2 balances = hook.getTotalBalances(key.toId());
        return LiquidityAmounts.getLiquidityForAmounts(amount0Desired, amount1Desired, balances, totalLiquidity);
    }

    /// @notice Create a new pool and add initial liquidity using the underlying token
    /// @dev The function is meant to be used via `eth_call` because it is a mutative function
    /// @param currency0 The underlying token address (Must match the underlying token of the PT)
    /// @param desiredImpliedRate The desired implied rate in wad (Note e.g. 0.185e18 for 18.5%)
    function quoteCreateAndAddLiquidity(
        Factory.Suite calldata suite,
        Factory.ModuleParam[] calldata modules,
        uint256 expiry,
        uint256 amount0Desired,
        uint256 desiredImpliedRate,
        address currency0
    ) external returns (PreviewAddLiquidityResult memory) {
        // Mine salt until the PT address (with factory hashing) is greater than the underlying token address
        uint256 salt = uint256(keccak256(abi.encode(block.timestamp, msg.sender)));
        Factory factory = principalTokenQuoter().factory();
        while (true) {
            bytes32 hashedSalt;
            assembly {
                // Must mirror Factory salt hashing: hash(chainid, msg.sender, salt)
                let m := mload(0x40)
                mstore(m, chainid())
                mstore(add(m, 0x20), address())
                mstore(add(m, 0x40), salt)
                hashedSalt := keccak256(m, 0x60)
            }

            address predictedAddress =
                LibBlueprint.computeCreate2Address(hashedSalt, suite.ptBlueprint, address(factory));
            if (predictedAddress > currency0) break;
            unchecked {
                salt++;
            }
        }
        (,, address pool) = factory.deployDeterministic(suite, modules, expiry, msg.sender, bytes32(salt));

        PoolKey memory key = TokiPoolToken(pool).i_poolKey();
        PrincipalToken pt = PrincipalToken(Currency.unwrap(key.currency1));

        ITokiHook.ImmutableParams memory immutables =
            ImmutableParamsLib.decodeFor.asImmutableParams()(ITokiHook(address(key.hooks)), key.toId());

        // Split initial liquidity
        uint256 initialProportion = TokiSwap.computeInitialProportion(
            immutables.expiry, immutables.scalarRoot, immutables.initialAnchor, desiredImpliedRate
        );

        // Remaining amount of underlying token `amount0 - amount0ToTokenize` is going to be left in the contract, then deposited to the pool later
        uint256 amount0ToTokenize = (amount0Desired * initialProportion) / 1e18;
        uint256 principals = pt.previewSupply(amount0ToTokenize);

        // Deposit the remaining underlying token and the PTs we just issued
        return quoteAddLiquidity(key, amount0Desired - amount0ToTokenize, principals);
    }

    function quoteAddLiquidityOneTokenKeepYt(PoolKey calldata key, Token token, uint256 amountDesired)
        external
        view
        checkPoolKey(key)
        returns (PreviewAddLiquidityResult memory result)
    {
        PrincipalToken pt = PrincipalToken(Currency.unwrap(key.currency1));

        uint256 amount0Total = principalTokenQuoter().vaultPreviewDeposit(pt, token, amountDesired);
        (uint256 amount0ToTokenize, uint256 amount1) = quoteSplitUnderlyingTokenLiquidityKeepYt(key, amount0Total);

        return quoteAddLiquidity(key, amount0Total - amount0ToTokenize, amount1);
    }

    function quoteAddLiquidityOneTokenNoYt(
        PoolKey calldata key,
        Token token,
        uint256 amountDesired,
        ApproximationParams calldata approx
    ) external view checkPoolKey(key) returns (PreviewAddLiquidityResult memory result) {
        uint256 amount0Total = principalTokenQuoter().vaultPreviewDeposit(
            PrincipalToken(Currency.unwrap(key.currency1)), token, amountDesired
        );
        (uint256 amount0In, uint256 amount1Out,, uint256 feeToCuratorAndProtocol) =
            quoteSplitUnderlyingTokenLiquidityNoYt(key, amount0Total, approx);

        Uint128x2 balances = ITokiHook(address(key.hooks)).getTotalBalances(key.toId());

        // The balances should be updated to reflect the new balances after the split
        balances = Packing.pack_uint128x2(
            (balances.value0() + amount0In - feeToCuratorAndProtocol).toUint128(),
            (balances.value1() - amount1Out).toUint128()
        );

        uint256 totalLiquidity = StateLibrary.getLiquidity(ITokiHook(address(key.hooks)), key.toId());
        result = _quoteAddLiquidity({
            key: key,
            balances: balances,
            totalLiquidity: totalLiquidity,
            amount0Desired: amount0Total - amount0In,
            amount1Desired: amount1Out
        });
        (result.spotExchangeRateBefore, result.executionExchangeRate, result.priceImpact) = previewPriceImpactPt(
            key,
            amount1Out.toInt256() // Positive because we're buying PT
        );
    }

    function quoteAddLiquidity(PoolKey memory key, uint256 amount0Desired, uint256 amount1Desired)
        public
        view
        checkPoolKey(key)
        returns (PreviewAddLiquidityResult memory)
    {
        ITokiHook hook = ITokiHook(address(key.hooks));
        Uint128x2 balances = hook.getTotalBalances(key.toId());
        uint256 totalLiquidity = StateLibrary.getLiquidity(hook, key.toId());
        return _quoteAddLiquidity({
            key: key,
            balances: balances,
            totalLiquidity: totalLiquidity,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired
        });
    }

    /// @dev Limitation 1: If vault doesn't spend exact amount in actual deposit, the preview may be inaccurate.
    function _quoteAddLiquidity(
        PoolKey memory key,
        Uint128x2 balances,
        uint256 totalLiquidity,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal view returns (PreviewAddLiquidityResult memory result) {
        ITokiHook hook = ITokiHook(address(key.hooks));

        // Compute liquidity for given amounts based on the current balance proportion.
        (, uint256 amount0, uint256 amount1) =
            LiquidityAmounts.getLiquidityForAmounts(amount0Desired, amount1Desired, balances, totalLiquidity);

        ITokiHook.ImmutableParams memory immutables = ImmutableParamsLib.decodeFor.asImmutableParams()(hook, key.toId());

        // Guard: adding liquidity is disabled after expiry
        LibExpiry.checkNotExpired(immutables.expiry);

        // Calculate deposit amounts for vaults
        uint256 depositAmount0 =
            LibRehypothecation.calculateDepositAmount(immutables.vault0, amount0, immutables.targetRawTokenRatio0);
        uint256 depositAmount1 =
            LibRehypothecation.calculateDepositAmount(immutables.vault1, amount1, immutables.targetRawTokenRatio1);

        // Deposit into vaults
        // Note: Limitation 1
        (, uint256 assets0) = LibRehypothecation.previewDeposit(immutables.vault0, depositAmount0);
        (, uint256 assets1) = LibRehypothecation.previewDeposit(immutables.vault1, depositAmount1);

        if (assets0 < depositAmount0) {
            amount0 -= depositAmount0 - assets0;
        }

        if (assets1 < depositAmount1) {
            amount1 -= depositAmount1 - assets1;
        }

        // Recalculate liquidity for amounts (with updated amounts, taking vault fees into account).
        (result.liquidity, amount0, amount1) =
            LiquidityAmounts.getLiquidityForAmounts(amount0, amount1, balances, totalLiquidity);

        uint256 maximumAllowance0 = amount0Desired - depositAmount0;
        uint256 rawAmount0 = _calculateRawAmount(immutables.vault0, assets0, amount0, maximumAllowance0);
        result.amount0Spent = rawAmount0 + depositAmount0;

        uint256 maximumAllowance1 = amount1Desired - depositAmount1;
        uint256 rawAmount1 = _calculateRawAmount(immutables.vault1, assets1, amount1, maximumAllowance1);
        result.amount1Spent = rawAmount1 + depositAmount1;
    }

    function _calculateRawAmount(ERC4626 vault, uint256 sharesInAsset, uint256 requiredAmount, uint256 maximumAllowance)
        internal
        pure
        returns (uint256 rawAmount)
    {
        if (requiredAmount > sharesInAsset) {
            // Deficit case: need to pull additional tokens from user
            rawAmount = requiredAmount - sharesInAsset;

            // Verify we don't exceed user's original allowance
            if (rawAmount > maximumAllowance) {
                // Extremely rare case or mathematically never happens
                revert Errors.TokiHook_InsufficientInputAmount(address(vault));
            }
        }
    }

    struct QuoteRemoveLiquidityResult {
        uint256 amount0Out;
        uint256 amount1Out;
    }

    /// @dev Returns total underlying/PT withdrawn when burning LP shares.
    function quoteRemoveLiquidity(PoolKey memory key, uint256 liquidity)
        public
        view
        checkPoolKey(key)
        returns (QuoteRemoveLiquidityResult memory result)
    {
        ITokiHook hook = ITokiHook(address(key.hooks));

        Uint128x2 reserves = Uint128x2.wrap(StateLibrary.getReserves(hook, key.toId()));
        Uint128x2 rawBalances = Uint128x2.wrap(StateLibrary.getRawBalances(hook, key.toId()));
        uint256 totalLiquidity = StateLibrary.getLiquidity(hook, key.toId());

        ITokiHook.ImmutableParams memory immutables = ImmutableParamsLib.decodeFor.asImmutableParams()(hook, key.toId());

        // forgefmt: disable-start
        (uint256 rawAmount0, uint256 rawAmount1) = LiquidityAmounts.getAmountsForLiquidity(liquidity, totalLiquidity, rawBalances);
        (uint256 shares0, uint256 shares1) = LiquidityAmounts.getAmountsForLiquidity(liquidity, totalLiquidity, reserves);
        (uint256 assets0, uint256 assets1) = (
            LibRehypothecation.getReservesInUnderlying(immutables.vault0, shares0),
            LibRehypothecation.getReservesInUnderlying(immutables.vault1, shares1)
        );
        // forgefmt: disable-end

        // Amounts withdrawn from vaults + raw amounts
        result.amount0Out = assets0 + rawAmount0;
        result.amount1Out = assets1 + rawAmount1;
    }

    struct QuoteRemoveLiquidityOneTokenResult {
        uint256 amountOut;
        int256 spotExchangeRateBefore;
        int256 executionExchangeRate;
        int256 priceImpact;
    }

    function quoteRemoveLiquidityOneToken(PoolKey calldata key, Token token, uint256 liquidity)
        external
        view
        checkPoolKey(key)
        returns (QuoteRemoveLiquidityOneTokenResult memory result)
    {
        ITokiHook.ImmutableParams memory immutables =
            ImmutableParamsLib.decodeFor.asImmutableParams()(ITokiHook(address(key.hooks)), key.toId());

        QuoteRemoveLiquidityResult memory preview = quoteRemoveLiquidity(key, liquidity);
        uint256 amount0Out = preview.amount0Out;

        if (LibExpiry.isExpired(immutables.expiry)) {
            PrincipalToken pt = PrincipalToken(Currency.unwrap(key.currency1));
            amount0Out += pt.previewRedeem(preview.amount1Out);
        } else {
            uint256 amount1Out = preview.amount1Out;
            (, TokiSwap.PoolState memory poolState,, FeePctsPool feePcts) = _buildPoolState(key);

            // The balances should be updated to reflect the new balances after the withdrawal
            poolState.balances = poolState.balances.sub(amount0Out.toUint128(), amount1Out.toUint128());

            // Calculate price impact
            (result.spotExchangeRateBefore,,) = TokiSwap.previewExchangeRate(
                poolState,
                TokiSwap.computeAmmParams(poolState, immutables, feePcts),
                -1 // Negative because we're selling PT
            );

            (result.executionExchangeRate,,) = TokiSwap.previewExchangeRate(
                poolState, TokiSwap.computeAmmParams(poolState, immutables, feePcts), -amount1Out.toInt256()
            );

            result.priceImpact = _calculateImpact(result.spotExchangeRateBefore, result.executionExchangeRate);

            // Execute swap calculation
            (int256 underlyingAmount,) = _dryRunSwap(poolState, immutables, feePcts, false, -amount1Out.toInt256());
            amount0Out += underlyingAmount.toUint256();
        }

        // Convert the vault shares to the desired token `token`
        result.amountOut =
            principalTokenQuoter().vaultPreviewRedeem(PrincipalToken(Currency.unwrap(key.currency1)), token, amount0Out);
    }

    /// @dev Result of the swap quote
    /// @param amountIn Amount of the token specified in the swap
    /// @param amountOut Amount of the token received from the swap
    /// @param executionExchangeRate Execution Price of PT in wad
    /// @param spotExchangeRateAfter Spot Price of PT after the swap in wad
    /// @param spotExchangeRateBefore Spot Price of PT before the swap in wad
    /// @param priceImpact Price Impact of the swap (PT or YT) in wad 100%=1e18
    struct QuoteSwapResult {
        uint256 amountIn;
        uint256 amountOut;
        int256 executionExchangeRate;
        int256 spotExchangeRateAfter;
        int256 spotExchangeRateBefore;
        int256 priceImpact;
    }

    /// @param zeroForOne true if the user is buying PT/YT, false if the user is selling PT/YT
    struct QuoteV4SwapParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amount;
        ApproximationParams approx;
    }

    /// @param zeroForOne true if the user is buying PT/YT, false if the user is selling PT/YT
    /// @param token the token the user pays if zeroForOne is true, the token the user receives if zeroForOne is false
    /// @param amount the amount of the token the user pays
    struct QuoteSwapParams {
        PoolKey poolKey;
        bool zeroForOne;
        Token token;
        uint128 amount;
        ApproximationParams approx;
    }

    function quoteSwapPt(QuoteSwapParams calldata params)
        external
        view
        checkPoolKey(params.poolKey)
        returns (QuoteSwapResult memory result)
    {
        PrincipalToken pt = PrincipalToken(Currency.unwrap(params.poolKey.currency1));
        PrincipalTokenQuoter quoter = principalTokenQuoter();

        if (params.zeroForOne) {
            // Buy PT with token
            // Convert token to underlying token first
            uint256 amount0 = quoter.vaultPreviewDeposit(pt, params.token, params.amount);
            result = _quoteV4SwapPt(
                QuoteV4SwapParams({
                    poolKey: params.poolKey,
                    zeroForOne: params.zeroForOne,
                    amount: amount0.toUint128(),
                    approx: params.approx
                })
            );
            if (!params.token.eq(pt.underlying())) {
                result.amountIn = params.amount;
            }
        } else {
            // Sell PT for token
            result = _quoteV4SwapPt(
                QuoteV4SwapParams({
                    poolKey: params.poolKey,
                    zeroForOne: params.zeroForOne,
                    amount: params.amount,
                    approx: params.approx
                })
            );
            // Convert the underlying token out to the desired token
            result.amountOut = quoter.vaultPreviewRedeem(pt, params.token, result.amountOut);
        }
    }

    function _quoteV4SwapPt(QuoteV4SwapParams memory params) internal view returns (QuoteSwapResult memory result) {
        // Build pool state for swap calculation
        (
            bool isExpired,
            TokiSwap.PoolState memory poolState,
            ITokiHook.ImmutableParams memory immutables,
            FeePctsPool feePcts
        ) = _buildPoolState(params.poolKey);

        if (isExpired) revert Errors.Expired();

        // Execute swap calculation
        (int256 underlyingAmount, int256 principals,,) = TokiSwap.swap(
            poolState,
            immutables,
            IPoolManager.SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: -params.amount.toInt256(), // Negative because we're selling tokens
                sqrtPriceLimitX96: 0
            }),
            params.approx,
            feePcts
        );

        if (params.zeroForOne) {
            // underlying -> PT swap
            // Note: due to binary search, the `underlyingAmount` is usually less than the `params.amount`
            result.amountIn = uint256(-underlyingAmount);
            result.amountOut = uint256(principals); // User receives PT (positive)
        } else {
            // PT -> underlying swap
            result.amountOut = uint256(underlyingAmount); // User receives underlying (positive)
            result.amountIn = params.amount; // User pays PT (positive)
        }

        // Preview spot exchange rate after the swap using the new pool state
        (result.spotExchangeRateAfter,,) =
            TokiSwap.previewExchangeRate(poolState, TokiSwap.computeAmmParams(poolState, immutables, feePcts), 0);

        // Preview effective exchange rate for the swap
        (result.spotExchangeRateBefore, result.executionExchangeRate, result.priceImpact) =
            previewPriceImpactPt(params.poolKey, principals);
    }

    function quoteSwapYt(QuoteSwapParams calldata params)
        external
        view
        checkPoolKey(params.poolKey)
        returns (QuoteSwapResult memory result)
    {
        PrincipalToken pt = PrincipalToken(Currency.unwrap(params.poolKey.currency1));
        PrincipalTokenQuoter quoter = principalTokenQuoter();

        if (params.zeroForOne) {
            // Buy YT with token
            // Convert token to underlying token first
            uint256 amount0 = quoter.vaultPreviewDeposit(pt, params.token, params.amount);
            result = _quoteV4SwapYt(
                QuoteV4SwapParams({
                    poolKey: params.poolKey,
                    zeroForOne: params.zeroForOne,
                    amount: amount0.toUint128(),
                    approx: params.approx
                })
            );
            // The actual spent amount is usually less than the amount of underlying token spent because of the binary search
            if (!params.token.eq(pt.underlying())) {
                result.amountIn = params.amount;
            }
        } else {
            // Sell YT for token
            result = _quoteV4SwapYt(
                QuoteV4SwapParams({
                    poolKey: params.poolKey,
                    zeroForOne: params.zeroForOne,
                    amount: params.amount,
                    approx: params.approx
                })
            );
            // Convert the underlying token out to the desired token
            result.amountOut = quoter.vaultPreviewRedeem(pt, params.token, result.amountOut);
        }
    }

    /// @dev actual spent amount is usually less than the amount if zeroForOne is true
    function _quoteV4SwapYt(QuoteV4SwapParams memory params) internal view returns (QuoteSwapResult memory result) {
        (
            bool isExpired,
            TokiSwap.PoolState memory poolState,
            ITokiHook.ImmutableParams memory immutables,
            FeePctsPool feePcts
        ) = _buildPoolState(params.poolKey);

        if (isExpired) revert Errors.Expired();

        // ZeroForOne: true means underlying -> YT swap
        int256 principals;
        if (params.zeroForOne) {
            // Binary search to find optimal PT amount to be flash swapped beforehand
            int256 bestUnderlying; // Positive
            uint256 underlyingDebt;

            (TokiSwapBinSearch i_tokiSwapBinSearch,,) = _parseImmutableArgs();
            (
                bestUnderlying,
                principals,
                /* uint256 bestSwapFee */
                ,
                /* uint256 bestFeeToCuratorAndProtocol */
                ,
                underlyingDebt
            ) = i_tokiSwapBinSearch.computeUnderlyingForYtSwap(params.poolKey, params.amount, params.approx);

            uint256 underlyingAvailable = uint256(bestUnderlying) + params.amount;

            if (underlyingDebt > underlyingAvailable) {
                // Something went wrong in the binary search or rounding error
                revert Errors.Zap_DebtExceedsUnderlyingReceived();
            }

            uint256 amountIn = params.amount;
            uint256 excess = underlyingAvailable - underlyingDebt; // The amount of underlying that is not going to be used

            result.amountIn = amountIn - excess; // Usually underflow shouldn't happen, or it means YT is free.
            result.amountOut = uint256(-principals);
        } else {
            // Calculate the amount of underlying needed to buy the exact amount of PTs on the market
            uint256 underlyingDebt;
            principals = params.amount.toInt256();
            {
                (int256 underlyingAmount,,,) = TokiSwap.computeSwapExactPrincipal(
                    poolState,
                    TokiSwap.computeAmmParams(poolState, immutables, feePcts),
                    principals // Exact-out swap
                );

                underlyingDebt = uint256(-underlyingAmount);
            }

            uint256 underlyingWithdrawn =
                PrincipalToken(Currency.unwrap(params.poolKey.currency1)).previewCombine(uint256(principals));

            if (underlyingWithdrawn < underlyingDebt) {
                revert Errors.Zap_DebtExceedsUnderlyingReceived();
            }

            result.amountIn = uint256(principals);
            result.amountOut = underlyingWithdrawn - underlyingDebt;
        }

        // Preview effective exchange rate for the swap
        (result.spotExchangeRateBefore, result.executionExchangeRate, result.priceImpact) =
            previewPriceImpactYt(params.poolKey, principals);

        // Preview spot exchange rate after the swap using the new pool state
        (result.spotExchangeRateAfter,,) =
            TokiSwap.previewExchangeRate(poolState, TokiSwap.computeAmmParams(poolState, immutables, feePcts), 0);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        PRICE IMPACT                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Preview price impact for PT swap
    /// @param key Pool key
    /// @param principals amount of PTs specified in the swap (positive for buy PT, negative for sell PT)
    /// @return spotExchangeRateBefore Spot exchange rate before the swap
    /// @return executionExchangeRate Execution exchange rate after the swap
    /// @return priceImpact Price impact of the swap
    function previewPriceImpactPt(PoolKey memory key, int256 principals)
        public
        view
        checkPoolKey(key)
        returns (int256 spotExchangeRateBefore, int256 executionExchangeRate, int256 priceImpact)
    {
        // Build pool state for swap calculation
        (
            bool isExpired,
            TokiSwap.PoolState memory poolState,
            ITokiHook.ImmutableParams memory immutables,
            FeePctsPool feePcts
        ) = _buildPoolState(key);

        if (isExpired) revert Errors.Expired();

        // Note: Instead of `previewExchangeRateNoFee` here, we try to get a more accurate spot exchange rate considering fees using `previewExchangeRate` with dust amount
        (spotExchangeRateBefore,,) = TokiSwap.previewExchangeRate(
            poolState,
            TokiSwap.computeAmmParams(poolState, immutables, feePcts),
            _sign(principals > 0) // 1 for buy PT (zeroForOne=true)
        );

        (executionExchangeRate,,) = TokiSwap.previewExchangeRate(
            poolState, TokiSwap.computeAmmParams(poolState, immutables, feePcts), principals
        );

        return (
            spotExchangeRateBefore,
            executionExchangeRate,
            _calculateImpact(spotExchangeRateBefore, executionExchangeRate)
        );
    }

    /// @dev Preview price impact for YT swap
    /// @param key Pool key
    /// @param principals amount of PTs specified in the swap. not the amount of YTs
    /// @return spotExchangeRateBefore Spot exchange rate before the swap
    /// @return executionExchangeRate Execution exchange rate after the swap
    /// @return priceImpact Price impact of the swap
    function previewPriceImpactYt(PoolKey memory key, int256 principals)
        public
        view
        checkPoolKey(key)
        returns (int256 spotExchangeRateBefore, int256 executionExchangeRate, int256 priceImpact)
    {
        (spotExchangeRateBefore, executionExchangeRate,) = previewPriceImpactPt(key, principals);

        int256 ytAssetExchangeRateBefore = _convertToYtPrice(spotExchangeRateBefore);
        int256 ytAssetExecutionExchangeRate = _convertToYtPrice(executionExchangeRate);
        priceImpact = _calculateImpact(ytAssetExchangeRateBefore, ytAssetExecutionExchangeRate);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         SPOT PRICE                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Don't use this function for oracle
    function convertLpToUnderlying(PoolKey memory key, uint256 liquidity)
        external
        view
        checkPoolKey(key)
        returns (uint256)
    {
        PrincipalToken pt = PrincipalToken(Currency.unwrap(key.currency1));
        // 1 LP => Assets => Underlying using the current conversion rate not the maxscale
        return TokiSwap.convertToUnderlying(convertLpToAssets(key, liquidity), pt.i_resolver().scale());
    }

    /// @dev Reference: https://github.com/pendle-finance/pendle-core-v2-public/blob/19317a9588b5fd68cc04e8f4b0f5613dac172e30/contracts/offchain-helpers/router-static/base/ActionMarketAuxStatic.sol#L191
    function convertPtToUnderlying(PoolKey memory key, uint256 principals)
        external
        view
        checkPoolKey(key)
        returns (uint256)
    {
        PrincipalToken pt = PrincipalToken(Currency.unwrap(key.currency1));
        return TokiSwap.convertToUnderlying(convertPtToAssets(key, principals), pt.i_resolver().scale());
    }

    function convertYtToUnderlying(PoolKey memory key, uint256 principals) external view returns (uint256) {
        PrincipalToken pt = PrincipalToken(Currency.unwrap(key.currency1));
        return TokiSwap.convertToUnderlying(convertYtToAssets(key, principals), pt.i_resolver().scale());
    }

    function convertLpToAssets(PoolKey memory key, uint256 liquidity) public view checkPoolKey(key) returns (uint256) {
        (bool isExpired, TokiSwap.PoolState memory poolState,,) = _buildPoolState(key);

        // If the pool is not initialized yet, the price is not defined yet
        if (poolState.totalLiquidity == 0) {
            return 0;
        }

        PrincipalToken pt = PrincipalToken(Currency.unwrap(key.currency1));
        uint256 maxscale = pt.getSnapshot().maxscale;
        uint256 cscale = pt.i_resolver().scale();
        if (cscale > maxscale) maxscale = cscale;

        uint256 totalRedeemableAssets;
        if (isExpired) {
            // 1 PT = 1 Asset post-expiry (excluding fees)
            totalRedeemableAssets =
                poolState.balances.value1() + TokiSwap.convertToAssets(poolState.balances.value0(), maxscale); // maxscale instead of cscale. See TokiSwap library for more details
        } else {
            totalRedeemableAssets = TokiSwap.convertToAssets(poolState.balances.value0(), maxscale)
                + convertPtToAssets(key, poolState.balances.value1());
        }

        return totalRedeemableAssets * liquidity / poolState.totalLiquidity;
    }

    /// @dev Reference: https://github.com/pendle-finance/pendle-core-v2-public/blob/19317a9588b5fd68cc04e8f4b0f5613dac172e30/contracts/offchain-helpers/router-static/base/ActionMarketAuxStatic.sol#L220
    function convertPtToAssets(PoolKey memory key, uint256 principals)
        public
        view
        checkPoolKey(key)
        returns (uint256)
    {
        (
            bool isExpired,
            TokiSwap.PoolState memory poolState,
            ITokiHook.ImmutableParams memory immutables,
            FeePctsPool feePcts
        ) = _buildPoolState(key);

        // CHANGED: Graceful fallback to 1:1 conversion when pool is not initialized yet
        if (poolState.totalLiquidity == 0) {
            return principals;
        }

        if (isExpired) {
            PrincipalToken pt = PrincipalToken(Currency.unwrap(key.currency1));
            // PT => Underlying => Assets using the current conversion rate not the maxscale
            return TokiSwap.convertToAssets(pt.convertToUnderlying(principals), pt.i_resolver().scale());
        }

        // CHANGED: Rehypothecation Awareness
        // Dry-run swap to refresh lnImpliedRate due to rehypothecation vault interest
        _dryRunSwap(poolState, immutables, feePcts, true, 0);

        uint256 timeToExpiry = immutables.expiry - block.timestamp;
        int256 assetToPtRate = TokiSwap.convertToExchangeRate(poolState.lnImpliedRate, timeToExpiry);
        return Constants.WAD * principals / assetToPtRate.toUint256();
    }

    function convertYtToAssets(PoolKey memory key, uint256 principals)
        public
        view
        checkPoolKey(key)
        returns (uint256)
    {
        return principals - convertPtToAssets(key, principals);
    }

    /// @notice Get the implied rate in wad (e^lnImpliedRate - 1) e.g. Note: 0.185e18 for 18.5%
    /// @dev Returns 0 if the pool is expired or has no liquidity
    function getImpliedRateWad(PoolKey memory key) external view checkPoolKey(key) returns (int256) {
        (
            bool isExpired,
            TokiSwap.PoolState memory poolState,
            ITokiHook.ImmutableParams memory immutables,
            FeePctsPool feePcts
        ) = _buildPoolState(key);

        if (isExpired || poolState.totalLiquidity == 0) {
            return 0;
        }

        _dryRunSwap(poolState, immutables, feePcts, true, 0);
        return FixedPointMathLib.expWad(uint256(poolState.lnImpliedRate).toInt256()) - TokiSwap.IWAD;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       MISCELLANEOUS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function computePoolParameters(uint256 rateMin, uint256 rateMax, uint256 expiry)
        external
        view
        returns (uint256 scalarRoot, int256 initialRateAnchor)
    {
        (scalarRoot, initialRateAnchor) = TokiSwap.computeOptimalParameters(rateMin, rateMax, expiry);
    }

    function computeOracleParameters(uint32 twapWindow, uint16 blockIntervalMs)
        external
        pure
        returns (uint16 cardinalityRequired)
    {
        cardinalityRequired = LibOracle.getCardinalityRequired(twapWindow, blockIntervalMs);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         HELPERS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _buildPoolState(PoolKey memory key)
        internal
        view
        returns (
            bool isExpired,
            TokiSwap.PoolState memory poolState,
            ITokiHook.ImmutableParams memory immutables,
            FeePctsPool feePcts
        )
    {
        ITokiHook hook = ITokiHook(address(key.hooks));
        immutables = ImmutableParamsLib.decodeFor.asImmutableParams()(hook, key.toId());

        isExpired = LibExpiry.isExpired(immutables.expiry);

        poolState = TokiSwap.PoolState({
            balances: hook.getTotalBalances(key.toId()),
            fees: Uint128x2.wrap(StateLibrary.getFees(hook, key.toId())),
            lnImpliedRate: StateLibrary.getLnImpliedRate(hook, key.toId()),
            totalLiquidity: StateLibrary.getLiquidity(hook, key.toId())
        });

        feePcts = PoolFeeModule(
            principalTokenQuoter().factory().moduleFor(address(immutables.principalToken), POOL_FEE_MODULE_INDEX)
        ).getFeePcts();
    }

    function _dryRunSwap(
        TokiSwap.PoolState memory poolState,
        ITokiHook.ImmutableParams memory immutables,
        FeePctsPool feePcts,
        bool zeroForOne,
        int256 amountSpecified
    ) internal view returns (int256 underlyingAmount, int256 principals) {
        ApproximationParams memory zeroApprox;
        // CHANGED: Dry-run Swap for Rate Refresh
        // Dry-run swap with 0-amount to refresh the lnImpliedRate without executing trades.
        //
        // KEY DIFFERENCE from Pendle:
        // - Pendle: lnImpliedRate remains static between trades
        // - Napier: lnImpliedRate changes continuously due to rehypothecation vault yield accrual
        //
        // Why this is needed:
        // - Rehypothecation vaults (e.g., Aave, Compound) earn interest continuously
        // - This changes the underlying asset value and affects PT pricing
        // - Without this refresh, quotes would become stale and inaccurate over time
        // - The dry-run simulates market dynamics to get current fair value
        (underlyingAmount, principals,,) = TokiSwap.swap(
            poolState,
            immutables,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0}),
            zeroApprox,
            feePcts
        );
    }

    function _calculateImpact(int256 rateBefore, int256 executionRate) internal pure returns (int256 priceImpact) {
        priceImpact = ((executionRate - rateBefore) * TokiSwap.IWAD) / rateBefore;
    }

    /// @dev No issuance/redemption fees are considered here
    function _convertToYtPrice(int256 exchangeRate) internal pure returns (int256 ytAssetExchangeRate) {
        // 1 asset = EX pt
        // 1 pt = 1/EX Asset
        // 1 yt + 1/EX Asset = 1 Asset
        // 1 yt = 1 Asset - 1/EX Asset
        // 1 yt = (EX - 1) / EX Asset
        return (exchangeRate - TokiSwap.IWAD) * TokiSwap.IWAD / exchangeRate;
    }

    function _sign(bool zeroForOne) internal pure returns (int256) {
        return TokiSwap.ternary(zeroForOne, 1, -1);
    }

    function _parseImmutableArgs()
        internal
        view
        returns (
            TokiSwapBinSearch i_tokiSwapBinSearch,
            TokiPoolDeployer i_tokiPoolDeployer,
            PrincipalTokenQuoter i_principalTokenQuoter
        )
    {
        (i_tokiSwapBinSearch, i_tokiPoolDeployer, i_principalTokenQuoter) = abi.decode(
            LibClone.argsOnERC1967I(address(this)), (TokiSwapBinSearch, TokiPoolDeployer, PrincipalTokenQuoter)
        );
    }

    modifier checkPoolKey(PoolKey memory key) {
        (, TokiPoolDeployer i_tokiPoolDeployer,) = _parseImmutableArgs();
        ContractValidation.checkTokiPoolExists(key.toId(), i_tokiPoolDeployer);
        _;
    }

    /// @dev It doesn't cover the case where deposit limit is reached
    /// @dev It doesn't cover the pause flags
    /// @dev Revert when PT issuance is unavailable (paused or expired)
    function _revertIfIssuanceDisabled(ITokiHook.ImmutableParams memory immutables) internal view {
        LibExpiry.checkNotExpired(immutables.expiry);
        if (immutables.principalToken.paused()) revert Errors.LibPauseGuard_Paused();
    }
}
