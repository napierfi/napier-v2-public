// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {MetadataReaderLib} from "solady/src/utils/MetadataReaderLib.sol";

import "../Types.sol";
import {WAD, TARGET_INDEX, PT_INDEX} from "../Constants.sol";

import {PrincipalToken} from "../tokens/PrincipalToken.sol";
import {LibTwoCryptoNG, TwoCrypto} from "./LibTwoCryptoNG.sol";

library ZapMathLib {
    using LibTwoCryptoNG for TwoCrypto;

    function computeSharesToTwoCrypto(TwoCrypto twoCrypto, PrincipalToken principalToken, uint256 shares)
        internal
        view
        returns (uint256 sharesToAMM)
    {
        // Initial liquidity -> Calculate based on initial_price param.
        // Assumption: Some of initial liquidity is permanently locked. So this branch runs only once per pool.
        if (twoCrypto.totalSupply() == 0) {
            // Adding liquidity in a ratio that (closely) matches the empty pool's initial price
            uint256 initialPrice = twoCrypto.last_prices();
            // Given 1 PT reserve, underlying token reserve should be `initialPrice` units of the underlying token
            uint256 underlyingDecimals = MetadataReaderLib.readDecimals(principalToken.underlying());
            uint256 underlyingReserveInPT = principalToken.previewSupply(10 ** underlyingDecimals * initialPrice / WAD);

            // sharesTokenize / initialLiquidity = principal / totalLiquidity
            // => sharesTokenize = shares * principal / (underlyingReserveInPT + principal)
            uint256 principal = 10 ** principalToken.decimals();
            uint256 sharesTokenized = FixedPointMathLib.mulDiv(shares, principal, underlyingReserveInPT + principal);
            sharesToAMM = shares - sharesTokenized;
        } else {
            uint256 ptReserve = twoCrypto.balances(PT_INDEX);
            uint256 underlyingReserve = twoCrypto.balances(TARGET_INDEX);
            uint256 underlyingReserveInPT = principalToken.previewSupply(underlyingReserve);

            // Liquidity added in a ratio that (closely) matches the existing pool's ratio
            // Formula: sharesToAMM / shares = underlyingReserveInPT / (underlyingReserveInPT + ptReserve)
            //      =>  sharesToAMM = shares * underlyingReserveInPT / (underlyingReserveInPT + ptReserve)
            sharesToAMM = FixedPointMathLib.mulDiv(shares, underlyingReserveInPT, underlyingReserveInPT + ptReserve);
        }
    }
}
