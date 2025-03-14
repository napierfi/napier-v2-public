// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";

type YieldIndex is uint128;

/// @param maxscale The last collected YBT share price in the underlying token.
/// @param globalIndex The accumulator of the accrued yield per YT.
struct Snapshot {
    uint128 maxscale;
    YieldIndex globalIndex;
}

struct Yield {
    YieldIndex userIndex;
    uint128 accrued;
}

using {unwrap} for YieldIndex global;
using {eq as ==, add as +, sub as -} for YieldIndex global;

function unwrap(YieldIndex x) pure returns (uint128 result) {
    result = YieldIndex.unwrap(x);
}

function wrap(uint128 x) pure returns (YieldIndex result) {
    result = YieldIndex.wrap(x);
}

function eq(YieldIndex lhs, YieldIndex rhs) pure returns (bool output) {
    assembly {
        let m := shr(128, not(0))
        output := eq(and(m, lhs), and(m, rhs))
    }
}

function add(YieldIndex lhs, YieldIndex rhs) pure returns (YieldIndex output) {
    output = wrap(lhs.unwrap() + rhs.unwrap());
}

function sub(YieldIndex lhs, YieldIndex rhs) pure returns (YieldIndex output) {
    output = wrap(lhs.unwrap() - rhs.unwrap());
}

/// @notice A library to help calculate yield for users.
/// @notice The yield is distributed proportionally to the user's YT balance.
/// @dev Conceptually, this algorithm is the same as the staking algorithm of Synthetix and MasterChef.
/// @dev Important security note: Any user may be griefed by a malicious user by updating the yield index frequently.
/// When small amount of yield is accrued and `ytSupply` is way larger than `totalAccrued`, those rewards may be lost.
/// Impact: The whole yield income for a user may be frozen.
/// @dev Note Yield-bearing token should have enough decimals and YT decimals should have no more than 18 decimals.
/// @dev Rebase token is not supported.
library YieldMathLib {
    using SafeCastLib for uint256;

    uint256 constant BASIS_POINTS = 10_000;

    /// @notice Compute the accrued yield
    /// @param prevMaxscale The last collected scale.
    /// @param newMaxscale The up-to-date scale at the time of computation. Non-zero value.
    /// @param supply The total PT supply backed by underlying tokens, which generates the yield.
    /// @param feePctBps The performance fee percentage to charge on the accrued yield.
    function computeTotalYield(uint256 prevMaxscale, uint256 newMaxscale, uint256 supply, uint256 feePctBps)
        internal
        pure
        returns (uint256 accrued, uint256 fee)
    {
        if (prevMaxscale == 0) return (0, 0);

        // Accrued yield depends on last collected newMaxscale and the current newMaxscale.
        uint256 totalAccrued = calcYield(prevMaxscale, newMaxscale, supply);

        // Performance fee is charged on the accrued yield.
        fee = FixedPointMathLib.mulDivUp(totalAccrued, feePctBps, BASIS_POINTS); // Round up against users.
        accrued = totalAccrued - fee;
    }

    /// @notice Update the yield index based on the `resolver`'s conversion rate before the expiry date.
    /// @dev This function doesn't check if the expiry date has passed or not.
    /// @dev Accrued yield is proportional to user's YT balance.
    /// @dev Every PT and YT supply change, the yield index must be updated to reflect the accrued yield since the last update.
    /// @dev `newIndex` is the cumulative accrued yield: Σ_i^N accruedYieldsPerYT_i = Σ_i (Δyields_i / ytSupply_i),
    /// where Δyields_i is the yield accrued by YTs during the i-th index update.
    /// Let N be the most recent update.
    ///
    /// During each update:
    ///   - The accrued yield by YTs is calculated as: Δyields_i = (1 / maxscale_{i-1} - 1 / maxscale_i) * ptSupply_i.
    ///
    /// A user's claimable yield is calculated using:
    /// ```
    /// (Σ_i^N accruedYieldsPerYT_i - Σ_i^{k} accruedYieldsPerYT_i) * user_ytBalance
    /// ```
    /// where `k` is the k-th update where the user's YT balance was changed.
    /// [k, k+1] defines the period where the user's balance is constant.
    /// Whenever a user's YT balance changes, their accrued yield is updated.
    ///
    /// ### Example:
    /// **Initial State:**
    /// - Alice issues 10 PTs/YTs for 10 shares (scale = 1).
    /// - Bob issues 10 PTs/YTs for 10 shares (scale = 1).
    /// - Initial index = 1.
    ///
    /// **Second Update:**
    /// - Scale increases to 2.
    /// - No change in index; yield generated is (1/1 - 1/2) * 20 = 10
    ///
    /// **Third Update:**
    /// - Alice claims her yield.
    /// - Scale increases to 4.
    /// - New index = 1 + (1/1 - 1/4) * 20 / 20 = 1 + 0.75 = 1.75
    /// - Alice claims 10 * (newIndex - prevUserIndex) = 10 * (1.75 - 1) = 7.5
    /// - Alice’s `userIndex` updates to 1.75
    /// - **Verification:** Alice's yield = 10 * (1/1 - 1/4) = 7.5
    ///
    /// **Fourth Update:**
    /// - Alice claims yield again.
    /// - Scale increases to 8.
    /// - New index = 1.75 + (1/4 - 1/8) * 20 / 20 = 1.75 + 0.125 = 1.875
    /// - Alice claims 10 * (1.875 - 1.75) = 1.25
    /// - Bob can accrue 10 * (1.875 - 1) = 8.75
    /// - **Verification:**
    ///   - Alice's yield = 10 * (1/4 - 1/8) = 1.25
    ///   - Bob's yield = 10 * (1/1 - 1/8) = 8.75
    ///
    /// **Fifth Update:**
    /// - Bob redeems 10 PT after expiry.
    /// - Scale increases to 10
    /// - New index = 1.875 + (1/8 - 1/10) * 20 / 20 = 1.875 + 0.025 = 1.9
    /// - Total accrued yield: (1/8 - 1/10) * 20 = 0.5
    /// - Alice and Bob can accrue 0.25 each.
    ///
    /// **Sixth Update:**
    /// - Alice and Bob claim yield (PT supply = 10, YT supply = 20).
    /// - Scale increases to 16.
    /// - New index = 1.9 + (1/10 - 1/16) * 10 / 20 = 1.9 + 0.01875 = 1.91875
    /// - Alice claims 10 * (1.91875 - 1.875) = 0.4375
    /// - Bob claims 10 * (1.91875 - 1) = 9.1875
    /// - **Verification:**
    ///   - Total yield since last step: (1/10 - 1/16) * 10 = 0.375
    ///   - Alice’s claim = 0.25 + (10/20) * 0.375 = 0.4375
    ///   - Bob’s claim = 8.75 + 0.25 + (10/20) * 0.375 = 9.1875
    /// @param scaleFn The function to fetch the up-to-date yield index. Must not return 0.
    /// @param ptSupply The total PT supply backed by underlying tokens, which generates the yield.
    /// @param ytSupply The total YT supply used as a denominator to distribute the generated yield.
    /// @param feePctBps The performance fee percentage to charge on the accrued yield in basis points.
    function updateIndex(
        Snapshot memory self,
        function () external view returns(uint256) scaleFn,
        uint256 ptSupply,
        uint256 ytSupply,
        uint256 feePctBps
    ) internal view returns (uint256 totalAccrued, uint256 fee) {
        // Cache the last maxscale and up-to-date maxscale.
        uint256 prevMaxscale = self.maxscale;
        uint256 newMaxscale = FixedPointMathLib.max(scaleFn(), prevMaxscale);

        (totalAccrued, fee) = computeTotalYield(prevMaxscale, newMaxscale, ptSupply, feePctBps);

        /// WRITE MEMORY
        self.maxscale = newMaxscale.toUint128();
        //                       N
        //                     _____
        //                     ╲
        //                      ╲    accrued
        //                       ╲          i
        // globalYieldIndex =    ╱   ─────────
        //                      ╱    ytSupply
        //                     ╱             i
        //                     ‾‾‾‾‾
        //                     i = 0
        // If supply is 0 but there is accrued yield, `totalAccrued - fee` is lost because index doesn't change.
        if (ytSupply == 0) return (totalAccrued, fee);
        self.globalIndex =
            self.globalIndex + YieldIndex.wrap(FixedPointMathLib.divWad(totalAccrued, ytSupply).toUint128());
    }

    /// @notice Update the accrued yield for a user `account` since the last time when `account` accrued yield based on the `account`'s YT balance `ytBalance`.
    /// @dev This function must be called every time the `account`'s YT balance changes.
    /// @param index The up-to-date yield index.
    /// @param account The account to update the yield for.
    /// @param ytBalance The `account`'s YT balance.
    function accrueUserYield(
        mapping(address => Yield) storage self,
        YieldIndex index, // yieldIndex(t_2)
        address account, // u
        uint256 ytBalance // ytBalance_u
    ) internal returns (uint256 accrued) {
        accrued = computeAccrueUserYield(self, index, account, ytBalance);

        self[account].accrued += accrued.toUint128();
        self[account].userIndex = index;
    }

    /// @notice Preview the accrued yield for a user `account` since the last time when `account` accrued yield based on the `account`'s YT balance `ytBalance`.
    function computeAccrueUserYield(
        mapping(address => Yield) storage self,
        YieldIndex index,
        address account,
        uint256 ytBalance
    ) internal view returns (uint256 accrued) {
        // dInterest  ⎛t ⎞     = dInterest  ⎛t ⎞  + ytBalance  ⋅ ⎛yieldIndex ⎛t ⎞ - yieldIndex ⎛t ⎞⎞
        //          u ⎝ 2⎠                u ⎝ 1⎠             u   ⎝           ⎝ 2⎠              ⎝ 1⎠⎠
        YieldIndex prevIndex = self[account].userIndex;
        accrued = FixedPointMathLib.mulWad(ytBalance, YieldIndex.unwrap(index - prevIndex));
    }

    /// @notice Compute the accrued yield based on maxscales.
    /// @dev Scales must be non-zero.
    function calcYield(uint256 prevMaxscale, uint256 maxscale, uint256 balance) internal pure returns (uint256) {
        if (prevMaxscale >= maxscale) return 0;
        if (prevMaxscale == 0) return 0;
        //                            ⎛   1        1  ⎞
        // dInterest = balance ⎛t ⎞ ⋅ ⎜────── - ──────⎟
        //                     ⎝ 1⎠   ⎜S ⎛t ⎞   S ⎛t ⎞⎟
        //                            ⎝  ⎝ 1⎠     ⎝ 2⎠⎠
        return ((balance * (maxscale - prevMaxscale)) * 1e18) / (prevMaxscale * maxscale);
    }

    /// @notice Convert YBT shares to principal.
    function convertToPrincipal(uint256 shares, uint256 maxscale, bool roundUp) internal pure returns (uint256) {
        // principal = shares * maxscale / 1e18
        return FixedPointMathLib.ternary(
            roundUp, FixedPointMathLib.mulWadUp(shares, maxscale), FixedPointMathLib.mulWad(shares, maxscale)
        );
    }

    /// @notice Convert principal to YBT shares.
    function convertToUnderlying(uint256 principal, uint256 maxscale, bool roundUp) internal pure returns (uint256) {
        // shares = principal * 1e18 / maxscale
        return FixedPointMathLib.ternary(
            roundUp, FixedPointMathLib.divWadUp(principal, maxscale), FixedPointMathLib.divWad(principal, maxscale)
        );
    }
}
