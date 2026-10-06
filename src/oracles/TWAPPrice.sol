// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ITokiHook, ImmutableParamsLib, StateLibrary} from "../interfaces/ITokiHook.sol";
import {TokiPoolToken} from "../tokens/TokiPoolToken.sol";
import {PrincipalToken} from "../tokens/PrincipalToken.sol";
import {PoolFeeModule} from "../modules/PoolFeeModule.sol";
import {TokiSwap} from "../utils/TokiSwap.sol";
import {ModuleAccessor} from "../utils/ModuleAccessor.sol";

import "../Types.sol";
import "../Errors.sol";
import "../Constants.sol" as Constants;

/// @dev Reference: https://github.com/pendle-finance/pendle-core-v2-public/blob/a9f5b99dbda7e6a8ec448cdd49c497a7499a0c3c/contracts/oracles/PtYtLpOracle/PendlePYOracleLib.sol
/// @dev Reference: https://github.com/pendle-finance/pendle-core-v2-public/blob/6d30e08b4b2dc298d3b26c8f98aa917f99e65bd1/contracts/oracles/PtYtLpOracle/PendleLpOracleLib.sol
/// @dev CHANGED: Some variables are renamed
/// @dev CHANGED: Dependencies are updated to modern libraries
/// @dev CHANGED: API is changed to convert amount of PT/YT/LP for clarity
/// @dev Important security note:
/// - Price oracle could NOT be reliable if a curator is not trusted
/// - Integrators MUST check if a pool is valid before calling any of the functions in this library
/// - Those functions revert if the pool does not have enough historical data
/// - Those functions revert if the pool does not have liquidity
/// @dev Oracle caveats:
///      Rehypothecation yield or vault share-price shocks can cause the oracle to diverge from
///      the spot price
library TWAPPrice {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;
    using ModuleAccessor for address;
    using SafeCastLib for *;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   ORACLE TO BASE TOKEN                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Convert PT to assets using TWAP price
    /// @param liquidityToken The TokiPool liquidity token address
    /// @param twapWindow TWAP twapWindow in seconds (0 for current price)
    /// @return PT price in asset token
    function convertPtToAssets(address liquidityToken, uint32 twapWindow, uint256 principals)
        internal
        view
        returns (uint256)
    {
        PoolKey memory key = getPoolKey(liquidityToken);
        (uint256 current, uint256 max) = getScales(Currency.unwrap(key.currency1));

        uint256 assets = _convertPtToAssetsRaw(key, twapWindow, principals);

        // CHANGED: The scale comparison is changed to `==` instead of `>=`
        // If everything works fine, maximum scale always equals to current, unlike Pendle
        // In our case we don't have native cache mechanism for vault share price
        if (current == max) {
            return assets;
        } else {
            return (assets * current) / max;
        }
    }

    /// @notice Convert YT to assets using TWAP price
    function convertYtToAssets(address liquidityToken, uint32 twapWindow, uint256 principals)
        internal
        view
        returns (uint256)
    {
        PoolKey memory key = getPoolKey(liquidityToken);
        (uint256 current, uint256 max) = getScales(Currency.unwrap(key.currency1));

        uint256 assets = _convertYtToAssetsRaw(key, twapWindow, principals);

        if (current == max) {
            return assets;
        } else {
            return (assets * current) / max;
        }
    }

    /// @notice Convert LP to assets using TWAP price
    function convertLpToAssets(address liquidityToken, uint32 twapWindow, uint256 liquidity)
        internal
        view
        returns (uint256)
    {
        PoolKey memory key = getPoolKey(liquidityToken);
        (uint256 current, uint256 max) = getScales(Currency.unwrap(key.currency1));

        uint256 assets = _convertLpToAssetsRaw(key, twapWindow, max, liquidity);

        if (current == max) {
            return assets;
        } else {
            return (assets * current) / max;
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*              ORACLE TO UNDERLYING TOKEN                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Convert PT to underlying token using TWAP price
    /// @param liquidityToken The TokiPool liquidity token address
    /// @param twapWindow TWAP twapWindow in seconds (0 for current price)
    /// @return PT price in underlying token
    function convertPtToUnderlying(address liquidityToken, uint32 twapWindow, uint256 principals)
        internal
        view
        returns (uint256)
    {
        PoolKey memory key = getPoolKey(liquidityToken);
        (uint256 current, uint256 max) = getScales(Currency.unwrap(key.currency1));

        uint256 assets = _convertPtToAssetsRaw(key, twapWindow, principals);

        uint256 scale = FixedPointMathLib.min(current, max);
        return TokiSwap.convertToUnderlying(assets, scale);
    }

    function convertYtToUnderlying(address liquidityToken, uint32 twapWindow, uint256 principals)
        internal
        view
        returns (uint256)
    {
        PoolKey memory key = getPoolKey(liquidityToken);
        (uint256 current, uint256 max) = getScales(Currency.unwrap(key.currency1));

        uint256 assets = _convertYtToAssetsRaw(key, twapWindow, principals);

        uint256 scale = FixedPointMathLib.min(current, max);
        return TokiSwap.convertToUnderlying(assets, scale);
    }

    function convertLpToUnderlying(address liquidityToken, uint32 twapWindow, uint256 liquidity)
        internal
        view
        returns (uint256)
    {
        PoolKey memory key = getPoolKey(liquidityToken);
        (uint256 current, uint256 max) = getScales(Currency.unwrap(key.currency1));

        uint256 assets = _convertLpToAssetsRaw(key, twapWindow, max, liquidity);

        uint256 scale = FixedPointMathLib.min(current, max);
        return TokiSwap.convertToUnderlying(assets, scale);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    INTERNAL FUNCTIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function getScales(address principalToken) internal view returns (uint256 current, uint256 max) {
        current = PrincipalToken(principalToken).i_resolver().scale();
        uint256 maxStored = PrincipalToken(principalToken).getSnapshot().maxscale;
        max = FixedPointMathLib.max(current, maxStored);
    }

    function _convertPtToAssetsRaw(PoolKey memory key, uint32 twapWindow, uint256 principals)
        internal
        view
        returns (uint256)
    {
        uint256 expiry = PrincipalToken(Currency.unwrap(key.currency1)).maturity();

        if (expiry <= block.timestamp) {
            return principals; // 1 PT = 1 Asset post-expiry (excluding fees)
        } else {
            uint256 timeToExpiry = expiry - block.timestamp;
            uint256 assetToPtRate =
                TokiSwap.convertToExchangeRate(_getTwapLnImpliedRate(key, twapWindow), timeToExpiry).toUint256();
            return Constants.WAD * principals / assetToPtRate;
        }
    }

    function _convertYtToAssetsRaw(PoolKey memory key, uint32 twapWindow, uint256 principals)
        internal
        view
        returns (uint256)
    {
        // YT = PT - Asset (excluding fees)
        return principals - _convertPtToAssetsRaw(key, twapWindow, principals);
    }

    /// For more details, see https://github.com/pendle-finance/pendle-core-v2-public/blob/6ca87b6e5a823d603cb8f66f983f5bc63b53218a/whitepapers/LP_Oracle.pdf
    /// @return The 1 unit of LP token in asset token units
    /// @dev Note LP Token is 18 decimals but 1 unit of LP token could be worth more than 2 Asset due to underlying token / asset decimals difference
    /// `sqrt(amount0 * amount1)` is initial LP tokens in raw
    /// Example: 1. Target token is eUSDC (18 decimals) and asset token is USDC (6 decimals). 1 eUSDC is 1e18.
    /// 1 LP token could be worth about 2e6 USDC (=2e6 * 10^6 in raw)
    /// Example: 2. Target token is yUSDC (6 decimals) and asset token is USDC (6 decimals). 1 yUSDC is 1e6.
    /// 1 LP token could be worth about 2e12 USDC (=2e12 * 10^12 in raw)
    function _convertLpToAssetsRaw(PoolKey memory key, uint32 twapWindow, uint256 maxscale, uint256 liquidity)
        internal
        view
        returns (uint256)
    {
        ITokiHook hook = ITokiHook(address(key.hooks));

        uint256 expiry = PrincipalToken(Currency.unwrap(key.currency1)).maturity();
        Uint128x2 balances = hook.getTotalBalances(key.toId());

        TokiSwap.PoolState memory poolState = TokiSwap.PoolState({
            balances: balances,
            fees: Uint128x2.wrap(StateLibrary.getFees(hook, key.toId())),
            lnImpliedRate: StateLibrary.getLnImpliedRate(hook, key.toId()),
            totalLiquidity: StateLibrary.getLiquidity(hook, key.toId())
        });

        int256 totalRedeemableAssets;
        if (expiry <= block.timestamp) {
            // 1 PT = 1 Asset post-expiry (excluding fees)
            totalRedeemableAssets =
                (balances.value1() + TokiSwap.convertToAssets(balances.value0(), maxscale)).toInt256();
        } else {
            ITokiHook.ImmutableParams memory immutables = ImmutableParamsLib.parse(hook, key.toId());

            TokiSwap.TokiAmmParams memory ammParams = TokiSwap.computeAmmParams(
                poolState,
                immutables,
                PoolFeeModule(immutables.principalToken.s_modules().get(POOL_FEE_MODULE_INDEX)).getFeePcts()
            );

            (int256 rateOracle, int256 rateBlended) =
                _computeExchangeRates(poolState.lnImpliedRate, key, twapWindow, expiry);

            int256 cParam = FixedPointMathLib.expWad(ammParams.rateScalar.sMulWad(rateOracle - ammParams.rateAnchor));

            int256 tradeSize = (
                cParam.sMulWad(ammParams.totalAssets.toInt256()) - uint256(balances.value1()).toInt256()
            ).sDivWad(TokiSwap.IWAD + cParam.sDivWad(rateBlended));

            totalRedeemableAssets = ammParams.totalAssets.toInt256() - tradeSize.sDivWad(rateBlended)
                + (uint256(balances.value1()).toInt256() + tradeSize).sDivWad(rateOracle);
        }

        return totalRedeemableAssets.toUint256() * liquidity / poolState.totalLiquidity;
    }

    /// @notice Get TWAP lnImpliedRate of the pool (0 for stored value)
    function _getTwapLnImpliedRate(PoolKey memory key, uint32 twapWindow) internal view returns (uint256) {
        ITokiHook hook = ITokiHook(address(key.hooks));

        // Make sure Principal Token is not in the middle of the call.
        // This is a workaround to trigger the `nonReadReentrant` modifier on the PrincipalToken.
        try PrincipalToken(Currency.unwrap(key.currency1)).isSettled() {}
        catch (bytes memory) {
            assembly {
                // Bubble up the revert if the call reverts.
                let fmp := mload(0x40)
                returndatacopy(fmp, 0x00, returndatasize())
                revert(fmp, returndatasize())
            }
        }

        if (twapWindow == 0) {
            return StateLibrary.getLnImpliedRate(hook, key.toId());
        }

        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = twapWindow;

        uint216[] memory lnImpliedRateCumulative = hook.observe(key, secondsAgo);
        return (lnImpliedRateCumulative[1] - lnImpliedRateCumulative[0]) / twapWindow;
    }

    function _computeExchangeRates(uint96 lastLnImpliedRate, PoolKey memory key, uint32 twapWindow, uint256 expiry)
        private
        view
        returns (int256 rateOracle, int256 rateBlended)
    {
        uint256 timeToExpiry = expiry - block.timestamp;

        uint256 twapLnImpliedRate = _getTwapLnImpliedRate(key, twapWindow);
        rateOracle = TokiSwap.convertToExchangeRate(twapLnImpliedRate, timeToExpiry);

        int256 rateLastTrade = TokiSwap.convertToExchangeRate(lastLnImpliedRate, timeToExpiry);

        rateBlended = (rateLastTrade + rateOracle) / 2;
    }

    function getPoolKey(address liquidityToken) internal view returns (PoolKey memory key) {
        key = TokiPoolToken(liquidityToken).i_poolKey();
    }
}
