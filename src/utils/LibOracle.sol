// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

/// Reference: https://github.com/pendle-finance/pendle-core-v2-internal/blob/6ca87b6e5a823d603cb8f66f983f5bc63b53218a/contracts/core/Market/OracleLib.sol

/// Adapted from UniswapV3's Oracle
/// Key differences from Uniswap V3 Oracle:
/// 1. Tracks lnImpliedRate instead of tick and liquidity
/// 2. No need for timestamp comparator (lte function)

/// @title Oracle library for logarithmic implied rate
/// @notice Provides lnImpliedRate data useful for a wide variety of system designs
/// @dev Instances of stored oracle data, "observations", are collected in the oracle array
/// Every pool is initialized with an oracle array length of 1. Anyone can pay the SSTOREs to increase the
/// maximum length of the oracle array. New slots will be added when the array is fully populated. Observations are
/// overwritten when the full length of the oracle array is populated. The most recent observation is available,
/// independent of the length of the oracle array, by passing 0 to observe()
library LibOracle {
    error LibOracle_OracleUninitialized();
    error LibOracle_OracleTargetTooOld(uint32 target, uint32 beforeOrAt);
    error LibOracle_OracleZeroCardinality();
    error LibOracle_TWAPWindowTooLarge(uint256 twapWindow, uint256 cardinalityRequired);

    uint16 constant MILLISECONDS_PER_SECOND = 1000;

    /// @notice A single oracle observation capturing the logarithmic implied rate at a point in time
    /// @dev Adapted from Uniswap V3's Observation struct, replacing tick/liquidity with lnImpliedRate
    struct Observation {
        uint32 blockTimestamp;
        uint216 lnImpliedRateCumulative;
        bool initialized;
    }

    /// @notice Transforms a previous observation into a new observation, given the passage of time and the current lnImpliedRate
    /// @dev blockTimestamp _must_ be chronologically equal to or greater than last.blockTimestamp, safe for 0 or 1 overflows
    /// @param last The specified observation to be transformed
    /// @param blockTimestamp The timestamp of the new observation
    /// @param lnImpliedRate The active logarithmic implied rate at the time of the new observation
    /// @return Observation The newly populated observation
    function transform(Observation memory last, uint32 blockTimestamp, uint96 lnImpliedRate)
        internal
        pure
        returns (Observation memory)
    {
        return Observation({
            blockTimestamp: blockTimestamp,
            lnImpliedRateCumulative: last.lnImpliedRateCumulative
                + uint216(lnImpliedRate) * (blockTimestamp - last.blockTimestamp),
            initialized: true
        });
    }

    /// @notice Initialize the oracle array by writing the first slot. Called once for the lifecycle of the observations array
    /// @param self The stored oracle array
    /// @param time The time of the oracle initialization, via block.timestamp truncated to uint32
    /// @return cardinality The number of populated elements in the oracle array
    /// @return cardinalityNext The new length of the oracle array, independent of population
    function initialize(Observation[65535] storage self, uint32 time)
        internal
        returns (uint16 cardinality, uint16 cardinalityNext)
    {
        self[0] = Observation({blockTimestamp: time, lnImpliedRateCumulative: 0, initialized: true});
        return (1, 1);
    }

    /// @notice Writes an oracle observation to the array
    /// @dev Writable at most once per block. Index represents the most recently written element. cardinality and index must be tracked externally.
    /// If the index is at the end of the allowable array length (according to cardinality), and the next cardinality
    /// is greater than the current one, cardinality may be increased. This restriction is created to preserve ordering.
    /// @param self The stored oracle array
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param blockTimestamp The timestamp of the new observation
    /// @param lnImpliedRate The active logarithmic implied rate at the time of the new observation
    /// @param cardinality The number of populated elements in the oracle array
    /// @param cardinalityNext The new length of the oracle array, independent of population
    /// @return indexUpdated The new index of the most recently written element in the oracle array
    /// @return cardinalityUpdated The new cardinality of the oracle array
    function write(
        Observation[65535] storage self,
        uint16 index,
        uint32 blockTimestamp,
        uint96 lnImpliedRate,
        uint16 cardinality,
        uint16 cardinalityNext
    ) internal returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        Observation memory last = self[index];

        // early return if we've already written an observation this block
        if (last.blockTimestamp == blockTimestamp) return (index, cardinality);

        // if the conditions are right, we can bump the cardinality
        if (cardinalityNext > cardinality && index == (cardinality - 1)) {
            cardinalityUpdated = cardinalityNext;
        } else {
            cardinalityUpdated = cardinality;
        }

        indexUpdated = (index + 1) % cardinalityUpdated;
        self[indexUpdated] = transform(last, blockTimestamp, lnImpliedRate);
    }

    /// @notice Prepares the oracle array to store up to `next` observations
    /// @param self The stored oracle array
    /// @param current The current next cardinality of the oracle array
    /// @param next The proposed next cardinality which will be populated in the oracle array
    /// @return uint16 The next cardinality which will be populated in the oracle array
    function grow(Observation[65535] storage self, uint16 current, uint16 next) internal returns (uint16) {
        if (current == 0) revert LibOracle_OracleUninitialized();
        // no-op if the passed next value isn't greater than the current next value
        if (next <= current) return current;
        // store in each slot to prevent fresh SSTOREs in swaps
        // this data will not be used because the initialized boolean is still false
        for (uint16 i = current; i != next;) {
            self[i].blockTimestamp = 1;
            unchecked {
                ++i;
            }
        }
        return next;
    }

    /// @notice Fetches the observations beforeOrAt and atOrAfter a target, i.e. where [beforeOrAt, atOrAfter] is satisfied.
    /// The result may be the same observation, or adjacent observations.
    /// @dev The answer must be contained in the array, used when the target is located within the stored observation
    /// boundaries: older than the most recent observation and younger, or the same age as, the oldest observation
    /// @param self The stored oracle array
    /// @param target The timestamp at which the reserved observation should be for
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param cardinality The number of populated elements in the oracle array
    /// @return beforeOrAt The observation recorded before, or at, the target
    /// @return atOrAfter The observation recorded at, or after, the target
    function binarySearch(Observation[65535] storage self, uint32 target, uint16 index, uint16 cardinality)
        internal
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        uint256 l = (index + 1) % cardinality; // oldest observation
        uint256 r = l + cardinality - 1; // newest observation
        uint256 i;
        while (true) {
            i = (l + r) / 2;

            beforeOrAt = self[i % cardinality];

            // we've landed on an uninitialized observation, keep searching higher (more recently)
            if (!beforeOrAt.initialized) {
                l = i + 1;
                continue;
            }

            atOrAfter = self[(i + 1) % cardinality];

            bool targetAtOrAfter = beforeOrAt.blockTimestamp <= target;

            // check if we've found the answer!
            if (targetAtOrAfter && target <= atOrAfter.blockTimestamp) break;

            if (!targetAtOrAfter) r = i - 1;
            else l = i + 1;
        }
    }

    /// @notice Fetches the observations beforeOrAt and atOrAfter a given target, i.e. where [beforeOrAt, atOrAfter] is satisfied
    /// @dev Assumes there is at least 1 initialized observation.
    /// Used by observeSingle() to compute the counterfactual accumulator values as of a given block timestamp.
    /// @param self The stored oracle array
    /// @param target The timestamp at which the reserved observation should be for
    /// @param lnImpliedRate The active logarithmic implied rate at the time of the returned or simulated observation
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param cardinality The number of populated elements in the oracle array
    /// @return beforeOrAt The observation which occurred at, or before, the given timestamp
    /// @return atOrAfter The observation which occurred at, or after, the given timestamp
    function getSurroundingObservations(
        Observation[65535] storage self,
        uint32 target,
        uint96 lnImpliedRate,
        uint16 index,
        uint16 cardinality
    ) internal view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        // optimistically set before to the newest observation
        beforeOrAt = self[index];

        // if the target is chronologically at or after the newest observation, we can early return
        if (beforeOrAt.blockTimestamp <= target) {
            if (beforeOrAt.blockTimestamp == target) {
                // if newest observation equals target, we're in the same block, so we can ignore atOrAfter
                return (beforeOrAt, atOrAfter);
            } else {
                // otherwise, we need to transform
                return (beforeOrAt, transform(beforeOrAt, target, lnImpliedRate));
            }
        }

        // now, set beforeOrAt to the oldest observation
        beforeOrAt = self[(index + 1) % cardinality];
        if (!beforeOrAt.initialized) beforeOrAt = self[0];

        // ensure that the target is chronologically at or after the oldest observation
        if (target < beforeOrAt.blockTimestamp) revert LibOracle_OracleTargetTooOld(target, beforeOrAt.blockTimestamp);

        // if we've reached this point, we have to binary search
        return binarySearch(self, target, index, cardinality);
    }

    /// @notice Returns the lnImpliedRate accumulator value as of `secondsAgo` from the given time
    /// @dev Reverts if an observation at or before the desired observation timestamp does not exist.
    /// 0 may be passed as `secondsAgo' to return the current cumulative values.
    /// If called with a timestamp falling between two observations, returns the counterfactual accumulator values
    /// at exactly the timestamp between the two observations.
    /// @param self The stored oracle array
    /// @param time The current block timestamp
    /// @param secondsAgo The amount of time to look back, in seconds, at which point to return an observation
    /// @param lnImpliedRate The current logarithmic implied rate
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param cardinality The number of populated elements in the oracle array
    /// @return lnImpliedRateCumulative The lnImpliedRate * time elapsed since the pool was first initialized, as of `secondsAgo`
    function observeSingle(
        Observation[65535] storage self,
        uint32 time,
        uint32 secondsAgo,
        uint96 lnImpliedRate,
        uint16 index,
        uint16 cardinality
    ) internal view returns (uint216 lnImpliedRateCumulative) {
        if (secondsAgo == 0) {
            Observation memory last = self[index];
            if (last.blockTimestamp != time) {
                return transform(last, time, lnImpliedRate).lnImpliedRateCumulative;
            }
            return last.lnImpliedRateCumulative;
        }

        uint32 target = time - secondsAgo;

        (Observation memory beforeOrAt, Observation memory atOrAfter) =
            getSurroundingObservations(self, target, lnImpliedRate, index, cardinality);

        if (target == beforeOrAt.blockTimestamp) {
            // we're at the left boundary
            return beforeOrAt.lnImpliedRateCumulative;
        } else if (target == atOrAfter.blockTimestamp) {
            // we're at the right boundary
            return atOrAfter.lnImpliedRateCumulative;
        } else {
            // we're in the middle
            return (
                beforeOrAt.lnImpliedRateCumulative
                    + uint216(
                        (
                            uint256(atOrAfter.lnImpliedRateCumulative - beforeOrAt.lnImpliedRateCumulative)
                                * (target - beforeOrAt.blockTimestamp)
                        ) / (atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp)
                    )
            );
        }
    }

    /// @notice Returns the accumulator values as of each time seconds ago from the given time in the array of `secondsAgos`
    /// @dev Reverts if `secondsAgos` > oldest observation
    /// @param self The stored oracle array
    /// @param time The current block.timestamp
    /// @param secondsAgos Each amount of time to look back, in seconds, at which point to return an observation
    /// @param lnImpliedRate The current logarithmic implied rate
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param cardinality The number of populated elements in the oracle array
    /// @return lnImpliedRateCumulative The lnImpliedRate * time elapsed since the pool was first initialized, as of each `secondsAgo`
    function observe(
        Observation[65535] storage self,
        uint32 time,
        uint32[] memory secondsAgos,
        uint96 lnImpliedRate,
        uint16 index,
        uint16 cardinality
    ) internal view returns (uint216[] memory lnImpliedRateCumulative) {
        if (cardinality == 0) revert LibOracle_OracleZeroCardinality();

        lnImpliedRateCumulative = new uint216[](secondsAgos.length);
        for (uint256 i = 0; i < lnImpliedRateCumulative.length; ++i) {
            lnImpliedRateCumulative[i] = observeSingle(self, time, secondsAgos[i], lnImpliedRate, index, cardinality);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     UTILITY FUNCTIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Calculate minimum cardinality needed for the given TWAP window
    /// @dev Formula: ceil(twapWindow * 1000 / blockIntervalMs) + 1
    /// @dev It must ensure we have enough capacity to store a given TWAP window data
    /// @dev Example: For 1-hour TWAP on Ethereum (11s blocks):
    ///      - Estimated blocks in 1 hour: ceil(3600 / 11) = 328 blocks
    ///      - Required cardinality: 328 + 1 = 329 slots
    ///      - This ensures 1-hour-old data always survives in the ring buffer
    /// @param twapWindow The TWAP window in seconds
    /// @param blockIntervalMs The block interval in milliseconds
    function getCardinalityRequired(uint32 twapWindow, uint16 blockIntervalMs) internal pure returns (uint16) {
        uint256 blocksInTwapWindow = FixedPointMathLib.divUp(twapWindow * MILLISECONDS_PER_SECOND, blockIntervalMs);
        uint256 cardinalityRequired = blocksInTwapWindow + 1;

        if (cardinalityRequired > type(uint16).max) {
            revert LibOracle_TWAPWindowTooLarge(twapWindow, cardinalityRequired);
        }

        return uint16(cardinalityRequired); // no unsafe cast
    }
}
