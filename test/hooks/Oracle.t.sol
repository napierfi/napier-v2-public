// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {LiquidityHookBase} from "./LiquidityHookBase.t.sol";
import {TokiHookHarness} from "../UniswapV4Base.t.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import {ITokiHook} from "src/interfaces/ITokiHook.sol";
import {LibOracle} from "src/utils/LibOracle.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

contract OracleTest is LiquidityHookBase {
    function setUp() public override {
        super.setUp();
        _addInitialLiquidity(alice, alice);
    }

    function test_OracleInitialization() public view {
        assertGe(stateOf(poolKey.toId()).observationCardinality, 1);
        assertGe(stateOf(poolKey.toId()).observationCardinalityNext, 1);
    }

    function test_ObservationAfterSwap() public {
        _testObservationAfterSwap({zeroForOne: false, amount: -1000, timeJump: 10000000});
    }

    /// @dev Test a observation is written correctly after a swap.
    function _testObservationAfterSwap(bool zeroForOne, int256 amount, uint256 timeJump) internal {
        uint256 lastIndex = stateOf(poolKey.toId()).observationIndex;
        LibOracle.Observation memory lastObservation =
            TokiHookHarness(address(tokiHook)).observationsOf(poolKey.toId(), lastIndex);

        uint96 lastLnImpliedRate = uint96(stateOf(poolKey.toId()).lnImpliedRate);

        _swap(alice, zeroForOne, amount, timeJump);

        uint256 newIndex = stateOf(poolKey.toId()).observationIndex;
        uint256 cardinalityNext = stateOf(poolKey.toId()).observationCardinalityNext;
        assertEq(newIndex, (lastIndex + 1) % cardinalityNext, "Observation index");

        // New cumulative based on the last lnImpliedRate
        uint256 expectedCumulative =
            LibOracle.transform(lastObservation, uint32(block.timestamp), lastLnImpliedRate).lnImpliedRateCumulative;

        LibOracle.Observation memory newObservation =
            TokiHookHarness(address(tokiHook)).observationsOf(poolKey.toId(), newIndex);
        assertEq(newObservation.blockTimestamp, block.timestamp, "timestamp");
        assertEq(newObservation.initialized, true, "initialized");
        assertEq(newObservation.lnImpliedRateCumulative, expectedCumulative, "cumulative");
    }

    function test_Observe() public {
        // Prepare - Increase cardinality next to avoid the array being fully populated.
        test_IncreaseObservationCardinalityNext();

        uint256 lastIndex = stateOf(poolKey.toId()).observationIndex;
        _testObservationAfterSwap({zeroForOne: false, amount: -1000, timeJump: 10000000});
        uint256 newIndex = stateOf(poolKey.toId()).observationIndex;

        assertEq(newIndex, lastIndex + 1, "Observation index incremented");

        uint32[] memory secondsAgo = new uint32[](1);
        secondsAgo[0] = 0; // 0 seconds ago (current time)
        uint216[] memory lnImpliedRateCumulative = tokiHook.observe(poolKey, secondsAgo);
        assertEq(lnImpliedRateCumulative.length, secondsAgo.length);
        assertGt(lnImpliedRateCumulative[0], 0);
    }

    function testFuzz_Observe(uint32 timeJump, uint32[] memory secondsAgo) public {
        // Record some observations
        _testObservationAfterSwap({zeroForOne: false, amount: -101, timeJump: 1000});

        _testObservationAfterSwap({zeroForOne: true, amount: 101, timeJump: 29021});

        timeJump = uint32(bound(timeJump, 1, expiry - block.timestamp));
        for (uint256 i = 0; i < secondsAgo.length; i++) {
            secondsAgo[i] = uint32(bound(secondsAgo[i], 0, timeJump - 1)); // -1 to avoid the initial observation
        }

        test_IncreaseObservationCardinalityNext();

        _testObservationAfterSwap({zeroForOne: false, amount: -10121, timeJump: timeJump});

        uint216[] memory lnImpliedRateCumulative = tokiHook.observe(poolKey, secondsAgo);
        assertEq(lnImpliedRateCumulative.length, secondsAgo.length);
        for (uint256 i = 0; i < secondsAgo.length; i++) {
            assertGt(lnImpliedRateCumulative[i], 0);
        }
    }

    function test_Observe_WhenExpired() public {
        test_IncreaseObservationCardinalityNext();

        _testObservationAfterSwap({zeroForOne: false, amount: -1000, timeJump: 10000000});

        vm.warp(expiry);

        uint32[] memory secondsAgo = new uint32[](1);
        secondsAgo[0] = 0; // 0 seconds ago (current time)
        uint216[] memory lnImpliedRateCumulative = tokiHook.observe(poolKey, secondsAgo);
        assertEq(lnImpliedRateCumulative.length, secondsAgo.length);
        assertGt(lnImpliedRateCumulative[0], 0);
    }

    function test_Observe_RevertWhen_BadPoolKey() public {
        PoolKey memory badKey = poolKey;
        badKey.fee = 2121;
        vm.expectRevert(Errors.BadTokiPool.selector);
        tokiHook.observe(badKey, new uint32[](0));
    }

    function test_Observe_RevertWhen_RequestedDataTooOld() public {
        test_IncreaseObservationCardinalityNext();

        _testObservationAfterSwap({zeroForOne: false, amount: -1000, timeJump: 1000});

        uint32[] memory secondsAgo = new uint32[](1);
        secondsAgo[0] = uint32(block.timestamp - 1001);
        try tokiHook.observe(poolKey, secondsAgo) {
            revert("Expected revert");
        } catch (bytes memory ret) {
            assertEq(bytes4(ret), LibOracle.LibOracle_OracleTargetTooOld.selector);
        }
    }

    function test_IncreaseObservationCardinalityNext() public {
        uint16 cardinalityNext = 900;
        tokiHook.increaseObservationsCardinalityNext(poolKey, cardinalityNext);
        assertEq(stateOf(poolKey.toId()).observationCardinalityNext, cardinalityNext);
    }

    function testFuzz_IncreaseObservationCardinalityNext(uint16 cardinalityNext, uint16 cardinalityNext2) public {
        cardinalityNext = uint16(bound(cardinalityNext, 0, 9000));
        cardinalityNext2 = uint16(bound(cardinalityNext2, 0, 9000));

        uint16 currentCardinalityNext = stateOf(poolKey.toId()).observationCardinalityNext;
        uint16 max = uint16(
            FixedPointMathLib.max(FixedPointMathLib.max(cardinalityNext, cardinalityNext2), currentCardinalityNext)
        );

        tokiHook.increaseObservationsCardinalityNext(poolKey, cardinalityNext);

        vm.warp(block.timestamp + 1000);

        tokiHook.increaseObservationsCardinalityNext(poolKey, cardinalityNext2);

        assertEq(stateOf(poolKey.toId()).observationCardinalityNext, max);
    }

    function test_IncreaseObservationCardinalityNext_RevertWhen_BadPoolKey() public {
        PoolKey memory badKey = poolKey;
        badKey.fee = 2121;
        vm.expectRevert(Errors.BadTokiPool.selector);
        tokiHook.increaseObservationsCardinalityNext(badKey, 100);
    }
}
