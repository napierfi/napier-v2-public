// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

import {PrincipalToken} from "../tokens/PrincipalToken.sol";
import {LibTwoCryptoNG} from "../utils/LibTwoCryptoNG.sol";
import {VaultInfoResolver} from "../modules/resolvers/VaultInfoResolver.sol";

import "../Types.sol";
import "../Constants.sol" as Constants;
import {Errors} from "../Errors.sol";

library ConversionLib {
    using LibTwoCryptoNG for TwoCrypto;
    using SafeCastLib for uint256;
    using SafeCastLib for int256;

    uint256 constant WAD = 1e18;

    /// @dev Convert shares to assets using scale
    /// @param shares Amount of shares to convert
    /// @param scale Scale factor (1 asset = scale * shares / WAD)
    /// @return Amount of assets
    function convertSharesToAssets(uint256 shares, uint256 scale) internal pure returns (uint256) {
        return (shares * scale) / WAD;
    }

    /// @dev Convert assets to USD using price
    /// @param assets Amount of assets to convert
    /// @param priceUSDInWad Price in USD with 18 decimals
    /// @return Amount in USD with 18 decimals
    function convertAssetsToUSD(uint256 assets, uint256 priceUSDInWad) internal pure returns (uint256) {
        return (assets * priceUSDInWad) / WAD;
    }

    /// @dev Convert price in asset units (wei) to implied APY
    /// @dev Zero div error on timeToExpiry == 0
    /// @dev Returns 0 if the `priceInAsset` == 0
    /// @param priceInAsset Price in asset (1e18)
    /// @param timeToExpiry Time until expiry in seconds
    /// @return impliedAPY Implied interest rate with 18 decimals (5% = 0.05e18)
    function convertToImpliedAPY(uint256 priceInAsset, uint256 timeToExpiry) internal pure returns (int256) {
        // Formula:
        //          1
        //          ─
        //          t
        //      ⎛FV⎞
        // i  = ⎜──⎟  - 1
        //  d   ⎝PV⎠

        // FV       1
        // ── = ─────────
        // PV   p ⋅ scale
        //      ─────────
        //        1e18
        // where `t` is the time to expiry in years and `p` is the price of the principal token in shares
        // `i_d` is the implied interest rate.
        // PV - Present value: Market price of the principal token in underlying token.
        // FV - Future value: Redemption value of the principal token in underlying token.
        //
        // For example, if a series of cDAI Principal Tokens matures in three months and has a price of 0.972 DAI, the implied yield to maturity is 12.03%.
        //            1
        //         ──────
        //          0.25
        //      ⎛  1  ⎞
        // i  = ⎜─────⎟  - 1
        //  d   ⎝0.972⎠
        if (priceInAsset == 0) return 0;
        uint256 fvDivPv = FixedPointMathLib.divWad(WAD, priceInAsset);
        uint256 oneDivTimeToExpiry = 365 days * WAD / timeToExpiry;
        return FixedPointMathLib.powWad(fvDivPv.toInt256(), oneDivTimeToExpiry.toInt256()) - int256(WAD);
    }

    /// @dev Convert price in asset units (wei) to implied APY
    /// @dev Returns 0 if the PT is expired
    function convertToImpliedAPY(address pt, uint256 priceInAsset) internal view returns (int256) {
        uint256 expiry = PrincipalToken(pt).maturity();
        if (expiry <= block.timestamp) return 0;
        return convertToImpliedAPY(priceInAsset, expiry - block.timestamp);
    }

    function convertToPriceInAsset(int256 impliedAPY, uint256 timeToExpiry)
        internal
        pure
        returns (uint256 priceInAsset)
    {
        // Formula:
        // p = [(1 + i) ^ -t] * 1e18 / scale
        // where `i` is the implied APY and `t` is the time to expiry in years
        uint256 timeToExpiryInYears = timeToExpiry * WAD / 365 days;
        priceInAsset = FixedPointMathLib.powWad(int256(WAD) + impliedAPY, -timeToExpiryInYears.toInt256()).toUint256();
    }

    /// @notice Price in 1e18
    function getYtPriceInUnderlying(TwoCrypto twoCrypto) internal view returns (uint256) {
        // The spot exchange rate between YBT and YT is evaluated using the tokenization equation without fees.
        // Let's say that we have a PT-pufETH/pufETH pool.
        // PT Price + YT Price = BaseAsset Price (ETH)
        // => 0.9 + 0.1 = 1 ETH (PT-pufETH/ETH = 0.9)
        // => 0.9 / 1.11 * 1.11 + 0.1 / 1.11 * 1.11 = 1 (pufETH/ETH = 1.11)
        // => 0.81 * 1.11 + 0.09 * 1.11 = 1

        // Symbolically:
        // => [PT Price in pufETH] * scale + x * scale = 1 where x is the YT price in pufETH
        // => x = (1 - [PT Price in pufETH] * scale) / scale
        // => x = 1/scale - [PT price in pufETH]

        // 1/x = scale / (1 - [PT Price in pufETH] * scale)

        PrincipalToken principalToken = PrincipalToken(twoCrypto.coins(Constants.PT_INDEX));

        uint256 ptPrinceInUnderlying = twoCrypto.last_prices();
        VaultInfoResolver resolver = principalToken.i_resolver();
        uint256 scale = resolver.scale();
        uint256 scaleUnit = 10 ** (18 + resolver.assetDecimals() - resolver.decimals());

        int256 ytPrice = int256(WAD * scaleUnit / scale) - int256(ptPrinceInUnderlying);
        if (ytPrice <= 0) revert Errors.ConversionLib_NegativeYtPrice(); // PT price is too high or scale is too low
        return uint256(ytPrice);
    }

    enum SwapKind {
        PT,
        YT
    }

    /// @notice Calculate the execution (effective) price based on the change of reserves before and after the swap.
    /// @notice Effective price is the price where actually the swap is executed.
    /// @param twoCrypto TwoCrypto instance
    /// @param principal Amount of PT in/out if kind=PT, amount of YT if kind=YT in/out
    /// @param shares shares in/out
    /// @param kind Swap kind
    /// @return priceWei Price of PT in asset if kind=PT, price of YT in asset if kind=YT.
    /// @notice If kind=PT, the return value can be greater than 1e18 which means that the PT is not discounted at all.
    /// @notice If kind=YT, the return value is in range [0, 1e18] if the YT price can be negative, returns 0.
    function calculateEffectivePtPrice(TwoCrypto twoCrypto, uint256 principal, uint256 shares, SwapKind kind)
        internal
        view
        returns (uint256 priceWei)
    {
        address pt = twoCrypto.coins(Constants.PT_INDEX);

        // Formula:
        // PT <-> any token: ptPrice = assets / ptAmount
        // YT <-> any token: ptPrice = 1 - assets / ytAmount

        uint256 assets = shares * PrincipalToken(pt).i_resolver().scale() / WAD; // 10**u * 10**(18 + b - u) / 10**18

        priceWei = assets * WAD / principal; // 10**b / 10**b * 10**18 = 10**18
        if (kind == SwapKind.YT) {
            priceWei = FixedPointMathLib.zeroFloorSub(WAD, priceWei); // max(0, WAD - priceWei)
        }
    }

    /// @notice Calculate the effective price given the delta of principal and amount of token in/out.
    /// @dev Price Impact formula:
    ///
    /// `priceImpact = (executionPrice - spotPrice) / spotPrice`
    ///
    /// For selling PT, prices are PT's prices measured in ETH. For buying PT, prices are ETH's prices measured in PT.
    ///
    /// Selling PT/YT
    ///
    /// Input: PT
    /// Output: tokenA (e.g., WBTC...)
    ///
    /// Spot price = spotPtPriceInUSD / tokenAPriceInUSD
    /// (In real life, a direct quote for token A and PT is not always available.)
    ///
    /// Execution price = outputTokenA / inputPT
    ///
    /// Example:
    /// - Spot PT price = $0.5
    /// - Token A price = $100
    /// - Input: 10 PT
    /// - Output: 0.05 token A
    /// - Spot price = 0.5 / 100 = 0.005
    /// - Execution price = 0.05 / 10 = 0.005
    ///
    /// ---
    ///
    /// Buying PT/YT follows a similar process.
    ///
    /// Input: tokenA
    /// Output: PT
    ///
    /// Spot price = tokenAPriceInUSD / spotPtPriceInUSD
    /// (In real life, a direct quote for token A and PT is not always available.)
    ///
    /// Execution price = outputPT / inputTokenA
    ///
    /// Example:
    /// - Spot PT price = $0.5
    /// - Token A price = $100
    /// - Input: 0.05 token A
    /// - Output: 10 PT
    /// - Spot price = 100 / 0.5 = 200
    /// - Execution price = 10 / 0.05 = 200
    function calculateEffectivePrice(Token tokenIn, Token tokenOut, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (uint256)
    {
        uint256 decimalsIn = tokenIn.isNative() ? 18 : tokenIn.erc20().decimals();
        uint256 decimalsOut = tokenOut.isNative() ? 18 : tokenOut.erc20().decimals();
        return amountOut * 10 ** (18 + decimalsIn - decimalsOut) / amountIn;
    }
}
