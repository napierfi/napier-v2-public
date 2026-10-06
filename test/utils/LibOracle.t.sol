// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";

import {LibOracle} from "../../src/utils/LibOracle.sol";

contract LibOracleTest is Test {
    function test_CardinalityRequired() public pure {
        uint32 twapWindow = 1 hours;
        uint16 blockIntervalMs = 11 seconds * 1000;
        uint16 cardinalityRequired = LibOracle.getCardinalityRequired(twapWindow, blockIntervalMs);
        assertEq(cardinalityRequired, 328 + 1);
    }

    function test_CardinalityRequired_RevertWhen_TwapWindowTooLarge() public view {
        uint32 twapWindow = 7 days;
        uint16 blockIntervalMs = 1000;

        try this.getCardinalityRequired(twapWindow, blockIntervalMs) {
            revert("Expected revert");
        } catch (bytes memory ret) {
            assertEq(bytes4(ret), LibOracle.LibOracle_TWAPWindowTooLarge.selector);
        }
    }

    function getCardinalityRequired(uint32 twapWindow, uint16 blockIntervalMs) public pure returns (uint16) {
        return LibOracle.getCardinalityRequired(twapWindow, blockIntervalMs);
    }
}
