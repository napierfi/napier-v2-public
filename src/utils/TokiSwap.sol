// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";

import {ITokiHook} from "../interfaces/ITokiHook.sol";

import "../Types.sol";
import "../Errors.sol";
import "../Constants.sol" as Constants;

import {FeePctsPoolLib} from "../utils/FeePctsPoolLib.sol";
import {YieldMathLib} from "../utils/YieldMathLib.sol";

/// @notice Math utilities for Uniswap V4 Custom Curve Hook (TokiPool)
library TokiSwap {
    using SafeCastLib for *;
    using FeePctsPoolLib for FeePctsPool;
    using {isEpsZero} for ApproximationParams;

    uint256 internal constant ONE_YEAR_IN_SECONDS = 365 days;
    int256 internal constant MAX_PROPORTION = (1e18 * 96) / 100; // 96%
    int256 internal constant IWAD = 1e18;
    int256 internal constant MAX_PT_CALCULATION_PRECISION = 0.999e18; // 99.9%
    int256 internal constant LN_9 = 2197224577336219382; // ln(9)
    uint256 internal constant DEFAULT_BINSEARCH_EPSILON = 0.00001e18; // 0.001% relative error
    uint256 internal constant MAX_BINSEARCH_EPSILON = 0.0005e18; // 0.05% relative error

    struct PoolState {
        Uint128x2 balances; // balance0, balance1
        Uint128x2 fees; // curator fees, protocol fees
        uint96 lnImpliedRate;
        uint128 totalLiquidity;
    }

    /// @notice Parameters for the TokiPool
    struct TokiAmmParams {
        uint256 totalAssets;
        int256 rateScalar;
        int256 rateAnchor;
        int256 feeRateWad;
        uint256 maxscale;
        FeePctsPool feePcts;
    }

    /// @dev Negative - Paid by user, Positive - Received by user
    /// @return underlyingAmount The amount of underlying token owed/taken from PoolManager
    /// @return principals The amount of principal token owed/taken from PoolManager
    /// @return swapFee The amount of underlying tokens charged for the swap
    /// @return feeToCuratorAndProtocol The sum of underlying tokens going to the curator and protocol
    function swap(
        PoolState memory state,
        ITokiHook.ImmutableParams memory immutables,
        IPoolManager.SwapParams memory params,
        ApproximationParams memory approx,
        FeePctsPool feePcts
    )
        internal
        view
        returns (int256 underlyingAmount, int256 principals, uint256 swapFee, uint256 feeToCuratorAndProtocol)
    {
        // At this point, we know hooklet#beforeSwap() has been called
        // and the following step applies the return values to TokiPool params
        TokiAmmParams memory ammParams = computeAmmParams(state, immutables, feePcts);

        // Currency0: rehypothecation vault, Currency1: principal token is assumed.

        // Compute swap result
        // If specified token is principal, no binsearch is needed
        // Otherwise, binsearch is needed
        if (params.zeroForOne == (params.amountSpecified >= 0)) {
            // exact in/out of principal token
            (underlyingAmount, principals, swapFee, feeToCuratorAndProtocol) =
                computeSwapExactPrincipal(state, ammParams, params.amountSpecified);
        } else {
            (underlyingAmount, principals, swapFee, feeToCuratorAndProtocol) =
                computeSwapExactUnderlying(state, ammParams, params.amountSpecified, approx);
        }

        // --------------------------------------------------------------------------------------------
        // Update memory
        // --------------------------------------------------------------------------------------------

        // Split fees between curator and protocol
        {
            uint256 curatorFee = feeToCuratorAndProtocol * ammParams.feePcts.getSplitPctBps() / Constants.BASIS_POINTS;
            uint256 protocolFee = FixedPointMathLib.rawSub(feeToCuratorAndProtocol, curatorFee); // no underflow

            state.fees = state.fees.add(curatorFee.toUint128(), protocolFee.toUint128());
        }

        {
            // balances0: underlying token
            // balances1: principal token
            uint256 balances0 = (state.balances.value0().toInt256() - underlyingAmount - feeToCuratorAndProtocol.toInt256()).toUint256();// forgefmt: disable-line
            uint256 balances1 = (state.balances.value1().toInt256() - principals).toUint256();
            state.balances = Packing.pack_uint128x2(balances0.toUint128(), balances1.toUint128());
        }

        // Update implied rate post-swap
        uint256 timeToExpiry;
        unchecked {
            timeToExpiry = immutables.expiry - block.timestamp;
        }
        state.lnImpliedRate = _getLnImpliedRate({
            totalAssets: convertToAssets(state.balances.value0(), ammParams.maxscale),
            totalPt: state.balances.value1(),
            rateScalar: ammParams.rateScalar,
            rateAnchor: ammParams.rateAnchor,
            timeToExpiry: timeToExpiry
        }).toUint96();

        if (state.lnImpliedRate == 0) revert Errors.TokiSwap_ImpliedRateZero();
    }

    /// @dev Revert if zero liquidity
    /// @dev Make sure it's not expired
    /// @dev Make sure it's not zero fee rate
    function computeAmmParams(PoolState memory state, ITokiHook.ImmutableParams memory immutables, FeePctsPool feePcts)
        internal
        view
        returns (TokiAmmParams memory result)
    {
        // Obvious sanity check - no liquidity
        if (state.balances.value0() == 0 || state.balances.value1() == 0) {
            revert Errors.TokiSwap_ZeroLiquidity();
        }

        // Get max scale
        uint256 maxscale = FixedPointMathLib.max(
            immutables.principalToken.getSnapshot().maxscale, immutables.principalToken.i_resolver().scale()
        );

        uint256 timeToExpiry = immutables.expiry - block.timestamp;

        result.feePcts = feePcts;
        result.maxscale = maxscale;
        result.rateScalar = _getRateScalar(immutables.scalarRoot, timeToExpiry);
        result.totalAssets = convertToAssets(state.balances.value0(), maxscale);

        result.rateAnchor = _getRateAnchor({
            totalAssets: result.totalAssets,
            totalPt: state.balances.value1(),
            lastLnImpliedRate: state.lnImpliedRate,
            rateScalar: result.rateScalar,
            timeToExpiry: timeToExpiry
        });

        unchecked {
            uint256 lnFeeRateRootWad =
                (uint256(feePcts.getAmmFeeParams()) * Constants.WAD) / Constants.TOKI_SWAP_FEE_SCALE; // no overflow
            result.feeRateWad = convertToExchangeRate(lnFeeRateRootWad, timeToExpiry);
        }
    }

    /// @notice Compute swap result for exact {in, out} of principal token
    /// @param amountSpecified The amount of principal token to be sold/bought (negative - sell, positive - buy)
    function computeSwapExactPrincipal(PoolState memory state, TokiAmmParams memory ammParams, int256 amountSpecified)
        internal
        pure
        returns (int256 underlyingAmount, int256 principals, uint256 swapFee, uint256 feeToCuratorAndProtocol)
    {
        // Can't buy more principal tokens than available
        if (state.balances.value1().toInt256() <= amountSpecified) {
            revert Errors.TokiSwap_InsufficientPrincipalsLiquidity();
        }

        (, int256 assets, int256 fee) = previewExchangeRate(state, ammParams, amountSpecified);

        uint256 assetsToCuratorAndProtocol =
            (uint256(fee) * ammParams.feePcts.getReserveFeePctBps()) / Constants.BASIS_POINTS;

        // Conversion from assets to shares
        underlyingAmount = convertToUnderlying(assets, ammParams.maxscale, assets < 0); // Round up if negative -> round up against the user
        swapFee = convertToUnderlyingUp(uint256(fee), ammParams.maxscale);
        feeToCuratorAndProtocol = convertToUnderlyingUp(assetsToCuratorAndProtocol, ammParams.maxscale);

        principals = amountSpecified;
    }

    /// @notice Preview effective exchange rate with fees for a principal token swap
    /// @param principals Amount of principal tokens to swap (positive=buy, negative=sell)
    /// @return exchangeRateWithFee Effective exchange rate including fees (PT per underlying)
    /// @return assets Net amount of assets after fees (negative=user pays, positive=user receives)
    /// @return fee Total fee amount in assets (always positive)
    function previewExchangeRate(PoolState memory state, TokiAmmParams memory ammParams, int256 principals)
        internal
        pure
        returns (int256 exchangeRateWithFee, int256 assets, int256 fee)
    {
        (int256 exchangeRateNoFee, int256 assetsNoFee) = previewExchangeRateNoFee(state, ammParams, principals); // > 1 always at this point
        int256 feeRate = ammParams.feeRateWad; // Can be zero

        // See whitepaper for the formula:
        // fee = assetsNoFee - assetsWithFee
        // Therefore:
        // fee = -(ptToAccount / exchangeRateNoFee) + (ptToAccount / exchangeRateWithFee)
        if (principals > 0) {
            // Path: User buys principal token
            // When buying PT, user pays more underlying tokens than the no-fee case

            // Exchange rate with fee is:
            //  `exchangeRateWithFee := exchangeRateNoFee / feeRate`
            // This means user needs to pay more underlying tokens per PT
            // Example: If no-fee exchange rate is 1.1 PT/underlying and fee rate is 1.02,
            // then with-fee exchange rate becomes 1.1/1.02 ≈ 1.078 PT/underlying

            // Revert if negative implied rate - effective exchange rate must be > 1 to ensure positive yield
            exchangeRateWithFee = exchangeRateNoFee * IWAD / feeRate;
            if (exchangeRateWithFee < IWAD) revert Errors.TokiSwap_ExchangeRateBelowOne(exchangeRateWithFee);

            // fee = -(ptToAccount / exchangeRateNoFee) + (ptToAccount / exchangeRateWithFee)
            //     = (ptToAccount / exchangeRateNoFee) * (feeRate - 1)
            //     = assetsNoFee * (feeRate - 1)

            // Equivalent: fee = assetsNoFee * (IWAD - feeRate) / IWAD with rounding up
            fee = FixedPointMathLib.mulWadUp(uint256(-assetsNoFee), uint256(feeRate - IWAD)).toInt256();
        } else {
            // Path: User sells principal token
            // When selling PT, user receives fewer underlying tokens than the no-fee case

            // Exchange rate with fee is:
            //  `exchangeRateWithFee := exchangeRateNoFee * feeRate`
            // This means user receives fewer underlying tokens per PT
            // Example: If no-fee exchange rate is 1.1 PT/underlying and fee rate is 1.02,
            // then with-fee exchange rate becomes 1.1 * 1.02 = 1.122 PT/underlying
            // Note: In this case, exchangeRateWithFee can't be below 1 since exchangeRateNoFee > 1

            // fee = -(ptToAccount / exchangeRateNoFee) + (ptToAccount / exchangeRateWithFee)
            //     = -(ptToAccount / exchangeRateNoFee) + (ptToAccount / (exchangeRateNoFee * feeRate))
            //     = -(ptToAccount / exchangeRateNoFee) * (1 - 1 / feeRate)
            //     = -(ptToAccount / exchangeRateNoFee) * (feeRate - 1) / feeRate
            //     = -assetsNoFee * (feeRate - 1) / feeRate
            exchangeRateWithFee = exchangeRateNoFee * feeRate / IWAD;
            // Equivalent: fee = -(assetsNoFee * (IWAD - feeRate)) / feeRate with rounding up
            fee = FixedPointMathLib.mulDivUp(uint256(assetsNoFee), uint256(feeRate - IWAD), uint256(feeRate)).toInt256();
        }
        assets = assetsNoFee - fee;
    }

    function previewExchangeRateNoFee(PoolState memory state, TokiAmmParams memory ammParams, int256 principals)
        internal
        pure
        returns (int256 exchangeRateNoFee, int256 assetsNoFee)
    {
        exchangeRateNoFee = _getExchangeRateNoFee({
            totalAssets: ammParams.totalAssets,
            totalPt: state.balances.value1(),
            rateScalar: ammParams.rateScalar,
            rateAnchor: ammParams.rateAnchor,
            netPtToAccount: principals
        });

        // `assetsNoFee = -principals * IWAD / exchangeRateNoFee`:
        // If principals is positive (user pays underlying tokens), we round up
        // If principals is negative (user receives underlying tokens), we round down

        if (principals > 0) {
            uint256 a = FixedPointMathLib.divWadUp(uint256(principals), uint256(exchangeRateNoFee));
            assetsNoFee = -a.toInt256();
        } else {
            uint256 a = FixedPointMathLib.divWad(uint256(-principals), uint256(exchangeRateNoFee));
            assetsNoFee = a.toInt256();
        }
    }

    /// @notice Compute swap result for exact {in, out} of underlying token
    /// @dev exact in: Actual amount in must be less than or equal to `abs(params.amountSpecified)`
    /// @dev exact out: Actual amount out must be greater than or equal to `abs(params.amountSpecified)`
    function computeSwapExactUnderlying(
        PoolState memory state,
        TokiAmmParams memory ammParams,
        int256 amountSpecified,
        ApproximationParams memory approx // Will be modified in-place
    )
        internal
        pure
        returns (int256 underlyingAmount, int256 principals, uint256 swapFee, uint256 feeToCuratorAndProtocol)
    {
        if (amountSpecified == 0) {
            return (0, 0, 0, 0);
        }

        if (approx.guessMin > approx.guessMax) {
            revert Errors.ApproximationParams_InvalidGuess();
        }

        if (amountSpecified > 0) revert Errors.TokiSwap_OnlyExactInSupported();

        // Path: User sells exact amount of underlying
        // Guesses must be positive or zero
        if (approx.guessMin < 0) revert Errors.ApproximationParams_InvalidGuess();

        // Check if epsilon is within the allowed range
        if (approx.eps > MAX_BINSEARCH_EPSILON) {
            revert Errors.ApproximationParams_InvalidEps();
        }

        return _binsearchExactUnderlyingIn(state, ammParams, amountSpecified, approx);
    }

    function _binsearchExactUnderlyingIn(
        PoolState memory state,
        TokiAmmParams memory ammParams,
        int256 amountSpecified, // Negative
        ApproximationParams memory approx
    )
        internal
        pure
        returns (int256 bestUnderlying, int256 bestPt, uint256 bestSwapFee, uint256 bestFeeToCuratorAndProtocol)
    {
        approx.guessMin = ternary(approx.isEpsZero(), 0, approx.guessMin);
        approx.guessMax = approx.isEpsZero() ? computeMaxPtOut(state, ammParams) : approx.guessMax;
        approx.eps = FixedPointMathLib.ternary(approx.isEpsZero(), DEFAULT_BINSEARCH_EPSILON, approx.eps);

        while (approx.guessMin <= approx.guessMax) {
            int256 mid = (approx.guessMin + approx.guessMax) / 2; // Assumption that mid doesn't overflow.
            (int256 uAmount,, uint256 sFee, uint256 fCurProt) = computeSwapExactPrincipal(state, ammParams, mid);

            if (uAmount < amountSpecified) {
                // Too much underlying required, try less PT
                approx.guessMax = mid - 1;
            } else {
                // Found a valid solution, cache it and try to find a better one
                bestPt = mid;
                bestUnderlying = uAmount;
                bestSwapFee = sFee;
                bestFeeToCuratorAndProtocol = fCurProt;

                // Calculate relative error and break if small enough
                // Both amountSpecified and uAmount are negative here
                int256 error_mid = ((amountSpecified - uAmount) * IWAD) / amountSpecified; // > 0

                if (error_mid < int256(approx.eps)) {
                    return (bestUnderlying, bestPt, bestSwapFee, bestFeeToCuratorAndProtocol);
                }

                approx.guessMin = mid + 1;
            }
        }

        revert Errors.TokiSwap_NoSolutionFound();
    }

    /// @notice To ensure interest rate continuity, we need to adjust the rateAnchor(t) every time swap runs.
    /// rateAnchor(t) = exp(lnLastImpliedRate * yearsToExpiry(t))
    ///                 - ln(p_prev / (1 - p_prev)) / rateScalar(t)
    function _getRateAnchor(
        uint256 totalAssets,
        uint256 totalPt,
        uint256 lastLnImpliedRate,
        int256 rateScalar,
        uint256 timeToExpiry
    ) internal pure returns (int256 rateAnchor) {
        int256 newExchangeRate = convertToExchangeRate(lastLnImpliedRate, timeToExpiry);

        // Underlying token must be more valuable than principal token at the spot
        // Otherwise, the implied rate is negative.
        // Reminder: newExchangeRate is the spot exchange rate of underlying token in principal token.
        if (newExchangeRate < IWAD) revert Errors.TokiSwap_ExchangeRateBelowOne(newExchangeRate);

        // ln(p_prev/(1-p_prev))
        uint256 proportion = totalPt * Constants.WAD / (totalPt + totalAssets);
        int256 lnProportion = _lnProportion(proportion.toInt256());

        // Apply formula
        rateAnchor = newExchangeRate - lnProportion * IWAD / rateScalar;
    }

    function _getLnImpliedRate(
        uint256 totalAssets,
        uint256 totalPt,
        int256 rateScalar,
        int256 rateAnchor,
        uint256 timeToExpiry
    ) internal pure returns (uint256 lnImpliedRate) {
        // This will check for exchange rates < 1
        int256 exchangeRate = _getExchangeRateNoFee({
            totalAssets: totalAssets,
            totalPt: totalPt,
            rateScalar: rateScalar,
            rateAnchor: rateAnchor,
            netPtToAccount: 0
        });

        // exchangeRate >= 1 so its ln >= 0
        uint256 lnRate = FixedPointMathLib.lnWad(exchangeRate).toUint256();
        lnImpliedRate = (lnRate * ONE_YEAR_IN_SECONDS) / timeToExpiry;
    }

    /// @notice Converts an implied rate (or lnFeeRate) to an exchange rate given a time to expiry. Formula is E = e^rt
    /// @return exchangeRate The spot exchange rate of underlying token against principal token.
    /// Practically, the exchange rate must be always greater than 1, which means the implied rate is always positive.
    function convertToExchangeRate(uint256 lnImpliedRate, uint256 timeToExpiry)
        internal
        pure
        returns (int256 exchangeRate)
    {
        uint256 rt = (lnImpliedRate * timeToExpiry) / ONE_YEAR_IN_SECONDS;
        exchangeRate = FixedPointMathLib.expWad(rt.toInt256());
    }

    /// @notice Get exchange rate given the amount of principal token to be sold/bought (Without trading fees)
    /// @param netPtToAccount The amount of principal token to be sold/bought. Negative - User sells principal token
    /// @dev Ensure that the totalPt > |netPtToAccount|
    function _getExchangeRateNoFee(
        uint256 totalAssets,
        uint256 totalPt,
        int256 rateScalar,
        int256 rateAnchor,
        int256 netPtToAccount
    ) internal pure returns (int256 exchangeRate) {
        int256 newTotalPt = totalPt.toInt256() - netPtToAccount;

        if (newTotalPt < 0) {
            revert Errors.TokiSwap_InsufficientPrincipalsLiquidity();
        }

        int256 proportion = newTotalPt * IWAD / (totalPt + totalAssets).toInt256();

        // Sanity check - Too much principal token is going to be in the pool
        if (proportion > MAX_PROPORTION) {
            revert Errors.TokiSwap_MarketProportionTooHigh();
        }

        int256 lnProportion = _lnProportion(proportion);
        exchangeRate = lnProportion * IWAD / rateScalar + rateAnchor;

        // Sanity check - Negative implied rate / Principal token in in premium is not allowed
        if (exchangeRate < IWAD) revert Errors.TokiSwap_ExchangeRateBelowOne(exchangeRate);
    }

    /// @notice Compute Logit function log(p/(1-p))
    /// @param proportion The proportion of principal token in the pool. (0 <= p < 1)
    /// @dev Revert if `proportion` is greater than 1.
    function _lnProportion(int256 proportion) internal pure returns (int256) {
        // Sanity check - Usually this should never happen
        if (proportion >= IWAD) revert Errors.TokiSwap_ProportionGreaterThanOne();

        int256 logitP = proportion * IWAD / (IWAD - proportion);
        return FixedPointMathLib.lnWad(logitP);
    }

    function _getRateScalar(uint256 scalarRoot, uint256 timeToExpiry) internal pure returns (int256) {
        uint256 rateScalar = (scalarRoot * ONE_YEAR_IN_SECONDS) / timeToExpiry;
        if (rateScalar == 0) revert Errors.TokiSwap_RateScalarZero();
        return rateScalar.toInt256();
    }

    /// @notice Compute the initial implied rate of the pool.
    /// @dev This function is expected to be called only once when initial liquidity is added.
    /// @return initialLnImpliedRate the initial implied rate
    function computeInitialLnImpliedRate(PoolState memory state, ITokiHook.ImmutableParams memory immutables)
        internal
        view
        returns (uint256)
    {
        uint256 maxscale = FixedPointMathLib.max(
            immutables.principalToken.getSnapshot().maxscale, immutables.principalToken.i_resolver().scale()
        );
        uint256 totalAssets = convertToAssets(state.balances.value0(), maxscale);

        unchecked {
            uint256 timeToExpiry = immutables.expiry - block.timestamp;
            int256 rateScalar = _getRateScalar(immutables.scalarRoot, timeToExpiry);
            return _getLnImpliedRate({
                totalAssets: totalAssets,
                totalPt: state.balances.value1(),
                rateScalar: rateScalar,
                rateAnchor: immutables.initialAnchor,
                timeToExpiry: timeToExpiry
            });
        }
    }

    /// @dev Chapter 4.2.1 of the whitepaper
    /// @notice Maximum amount of principal token is capped by the fact that effective exchange rate (exchange rate with fees) must be greater or equal to 1.
    /// @dev It can be over 5% different from the actual maximum amount of PT that can be bought.
    /// @dev The return value is always positive
    function computeMaxPtOut(PoolState memory state, TokiAmmParams memory ammParams) internal pure returns (int256) {
        int256 logitP =
            FixedPointMathLib.expWad((ammParams.feeRateWad - ammParams.rateAnchor) * ammParams.rateScalar / IWAD);
        int256 proportion = logitP * IWAD / (logitP + IWAD);
        int256 numerator = proportion * (state.balances.value1() + ammParams.totalAssets).toInt256() / IWAD;
        int256 maxPtOut = state.balances.value1().toInt256() - numerator;
        maxPtOut = FixedPointMathLib.max(maxPtOut, 0);
        // It can be negative, which means exchange rate has been already 1
        // Get 99.9% of the theoretical max to accommodate some precision issues
        return FixedPointMathLib.max((maxPtOut * MAX_PT_CALCULATION_PRECISION) / IWAD, 0);
    }

    /// @dev Chapter 4.2.2 of the whitepaper
    /// @dev It can be over 5% different from the actual maximum amount of PT that can be sold.
    /// @dev The return value is always negative
    function computeMaxPtIn(PoolState memory state, TokiAmmParams memory ammParams) internal pure returns (int256) {
        uint256 low;
        uint256 hi = ammParams.totalAssets - 1;
        uint256 totalPt = state.balances.value1();

        while (low != hi) {
            uint256 mid = (low + hi + 1) / 2;
            if (_calcSlope(ammParams, totalPt, mid) < 0) hi = mid - 1;
            else low = mid;
        }

        low = FixedPointMathLib.min(
            low, uint256(MAX_PROPORTION) * (totalPt + ammParams.totalAssets) / Constants.WAD - totalPt
        );
        return -low.toInt256();
    }

    function _calcSlope(TokiAmmParams memory ammParams, uint256 totalPt, uint256 principals)
        internal
        pure
        returns (int256)
    {
        uint256 delta = ammParams.totalAssets - principals;
        uint256 newTotalPt = principals + totalPt;

        uint256 term1 = (principals * (totalPt + ammParams.totalAssets)) * Constants.WAD / (newTotalPt * delta);

        int256 term2 = FixedPointMathLib.lnWad((newTotalPt * Constants.WAD / delta).toInt256());
        int256 term3 = IWAD * IWAD / ammParams.rateScalar;

        return ammParams.rateAnchor - (term1.toInt256() - term2) * term3 / IWAD;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        INITIALIZATION                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Compute an optimal parameters for initializing a TokiPool pool
    /// @dev Taken from: https://github.com/pendle-finance/pendle-core-v2-public/blob/edaaf2b00760a47b86812efc263bdd916349c8c6/contracts/offchain-helpers/deploy/lib/MarketDeployLib.sol#L23
    /// @param rateMin The minimum rate in wad (Note e.g. 0.085e18 for 8.5%)
    /// @param rateMax The maximum rate in wad
    /// @param expiry The expiry timestamp (block.timestamp + 1 year for 1 year expiry)
    function computeOptimalParameters(uint256 rateMin, uint256 rateMax, uint256 expiry)
        internal
        view
        returns (uint256 scalarRoot, int256 initialRateAnchor)
    {
        if (rateMin >= rateMax) revert Errors.TokiSwap_BadRateRange();

        int256 yearsToExpiry = ((expiry - block.timestamp) * Constants.WAD / ONE_YEAR_IN_SECONDS).toInt256();
        int256 _rateMin = FixedPointMathLib.powWad(rateMin.toInt256() + IWAD, yearsToExpiry);
        int256 _rateMax = FixedPointMathLib.powWad(rateMax.toInt256() + IWAD, yearsToExpiry);

        // [initRateAnchor]
        initialRateAnchor = (_rateMin + _rateMax) / 2;

        // [scalarRoot]
        int256 rateDiff = _rateMax - initialRateAnchor;
        scalarRoot = ((LN_9 * yearsToExpiry) / rateDiff).toUint256();
    }

    /// @notice Compute an optimal proportion of principal token in the pool.
    /// @param desiredImpliedRate The desired implied rate in wad (Note e.g. 0.185e18 for 18.5%)
    /// @dev Taken from: https://github.com/pendle-finance/pendle-core-v2-public/blob/edaaf2b00760a47b86812efc263bdd916349c8c6/contracts/offchain-helpers/deploy/lib/MarketDeployLib.sol#L50
    /// @dev [Underlying deposited into Principal Token] = [Seed Underlying Liquidity] * [Initial Proportion]
    function computeInitialProportion(uint256 expiry, uint256 scalarRoot, int256 rateAnchor, uint256 desiredImpliedRate)
        internal
        view
        returns (uint256 initialProportion)
    {
        uint256 timeToExpiry = expiry - block.timestamp;
        int256 lnImpliedRate = FixedPointMathLib.lnWad(IWAD + desiredImpliedRate.toInt256());

        int256 desiredExchangeRate = convertToExchangeRate(lnImpliedRate.toUint256(), timeToExpiry);
        int256 rateScalar = _getRateScalar(scalarRoot, timeToExpiry);
        int256 logitP = FixedPointMathLib.expWad((desiredExchangeRate - rateAnchor) * rateScalar / IWAD);
        initialProportion = (logitP * IWAD / (IWAD + logitP)).toUint256();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CONVERSION                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Convert shares (underlying) to assets
    function convertToAssets(uint256 shares, uint256 maxscale) internal pure returns (uint256 assets) {
        assets = YieldMathLib.convertToPrincipal(shares, maxscale, false);
    }

    function convertToUnderlying(uint256 assets, uint256 maxscale) internal pure returns (uint256 shares) {
        shares = YieldMathLib.convertToUnderlying(assets, maxscale, false);
    }

    function convertToUnderlyingUp(uint256 assets, uint256 maxscale) internal pure returns (uint256 shares) {
        shares = YieldMathLib.convertToUnderlying(assets, maxscale, true);
    }

    /// @notice Convert assets to shares (underlying)
    function convertToUnderlying(int256 assets, uint256 maxscale, bool roundUp) internal pure returns (int256 shares) {
        unchecked {
            int256 s = sign(assets);
            shares = s * (YieldMathLib.convertToUnderlying(uint256(s * assets), maxscale, roundUp)).toInt256();
        }
    }

    /// @notice Branchless sign function
    /// @return s = 1 if x > 0, -1 if x < 0, 0 if x == 0
    function sign(int256 x) internal pure returns (int256 s) {
        assembly {
            // s = (x > 0) - (x < 0)
            s := sub(sgt(x, 0), slt(x, 0))
        }
    }

    /// @dev Returns `condition ? x : y`, without branching.
    function ternary(bool condition, int256 x, int256 y) internal pure returns (int256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            z := xor(x, mul(xor(x, y), iszero(condition)))
        }
    }
}
